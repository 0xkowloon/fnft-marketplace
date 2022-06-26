// SPDX-License-Identifier: MIT

pragma solidity 0.8.13;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/structs/EnumerableSetUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC1155/IERC1155Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/interfaces/IERC3156FlashBorrowerUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/utils/ERC721HolderUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC1155/utils/ERC1155HolderUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/interfaces/IERC165Upgradeable.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import "./interfaces/IFNFTCollection.sol";
import "./interfaces/IFNFTCollectionFactory.sol";
import "./interfaces/IVaultManager.sol";
import "./interfaces/IEligibility.sol";
import "./interfaces/IEligibilityManager.sol";
import "./interfaces/IFeeDistributor.sol";
import "./token/ERC20FlashMintUpgradeable.sol";
import {IPriceOracle} from "./PriceOracle.sol";

// Authors: @0xKiwi_ and @alexgausman.

contract FNFTCollection is
    OwnableUpgradeable,
    IFNFTCollection,
    IERC165,
    ERC20FlashMintUpgradeable,
    ReentrancyGuardUpgradeable,
    ERC721HolderUpgradeable,
    ERC1155HolderUpgradeable
{
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.UintSet;

    uint256 constant base = 10**18;

    uint256 public override vaultId;
    address public override manager;
    address public override pair;
    IVaultManager public override vaultManager;
    IFNFTCollectionFactory public override factory;
    IEligibility public override eligibilityStorage;

    uint256 randNonce;

    address public override assetAddress;
    bool public override is1155;
    bool public override allowAllItems;
    bool public override enableMint;
    bool public override enableRandomRedeem;
    bool public override enableTargetRedeem;
    bool public override enableRandomSwap;
    bool public override enableTargetSwap;

    EnumerableSetUpgradeable.UintSet holdings;
    mapping(uint256 => uint256) quantity1155;

    event VaultShutdown(address assetAddress, uint256 numItems, address recipient);

    error ZeroAddress();
    error IneligibleNFTs();
    error ZeroTransferAmount();
    error NotOwner();
    error NotManager();
    error Paused();
    error TooManyNFTs();
    error EligibilityAlreadySet();
    error MintDisabled();
    error RandomRedeemDisabled();
    error TargetRedeemDisabled();
    error RandomSwapDisabled();
    error TargetSwapDisabled();
    error NFTAlreadyInCollection();
    error NotNFTOwner();
    error FeeTooHigh();
    error WrongToken();

    function __FNFTCollection_init(
        string memory _name,
        string memory _symbol,
        address _assetAddress,
        bool _is1155,
        bool _allowAllItems
    ) public override virtual initializer {
        __Ownable_init();
        __ERC20_init(_name, _symbol);
        if (_assetAddress == address(0)) revert ZeroAddress();
        IFNFTCollectionFactory _factory = IFNFTCollectionFactory(msg.sender);
        vaultManager = IVaultManager(_factory.vaultManager());
        assetAddress = _assetAddress;
        factory = _factory;
        vaultId = vaultManager.numVaults();
        is1155 = _is1155;
        allowAllItems = _allowAllItems;
        pair = IPriceOracle(vaultManager.priceOracle()).createFNFTPair(address(this));
        emit VaultInit(vaultId, _assetAddress, _is1155, _allowAllItems);
        setVaultFeatures(true /*enableMint*/, true /*enableRandomRedeem*/, true /*enableTargetRedeem*/, true /*enableRandomSwap*/, true /*enableTargetSwap*/);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC1155ReceiverUpgradeable, IERC165) returns (bool) {
        return interfaceId == type(IFNFTCollection).interfaceId ||
                interfaceId == type(IERC165).interfaceId ||
                super.supportsInterface(interfaceId);
    }

    function finalizeVault() external override virtual {
        setManager(address(0));
    }

    function setVaultMetadata(
        string calldata name_,
        string calldata symbol_
    ) external override virtual {
        onlyPrivileged();
        _setMetadata(name_, symbol_);
    }

    function setVaultFeatures(
        bool _enableMint,
        bool _enableRandomRedeem,
        bool _enableTargetRedeem,
        bool _enableRandomSwap,
        bool _enableTargetSwap
    ) public override virtual {
        onlyPrivileged();
        enableMint = _enableMint;
        enableRandomRedeem = _enableRandomRedeem;
        enableTargetRedeem = _enableTargetRedeem;
        enableRandomSwap = _enableRandomSwap;
        enableTargetSwap = _enableTargetSwap;

        emit EnableMintUpdated(_enableMint);
        emit EnableRandomRedeemUpdated(_enableRandomRedeem);
        emit EnableTargetRedeemUpdated(_enableTargetRedeem);
        emit EnableRandomSwapUpdated(_enableRandomSwap);
        emit EnableTargetSwapUpdated(_enableTargetSwap);
    }

    function setFees(
        uint256 _mintFee,
        uint256 _randomRedeemFee,
        uint256 _targetRedeemFee,
        uint256 _randomSwapFee,
        uint256 _targetSwapFee
    ) public override virtual {
        onlyPrivileged();
        factory.setVaultFees(vaultId, _mintFee, _randomRedeemFee, _targetRedeemFee, _randomSwapFee, _targetSwapFee);
    }

    function disableVaultFees() public override virtual {
        onlyPrivileged();
        factory.disableVaultFees(vaultId);
    }

    // This function allows for an easy setup of any eligibility module contract from the EligibilityManager.
    // It takes in ABI encoded parameters for the desired module. This is to make sure they can all follow
    // a similar interface.
    function deployEligibilityStorage(
        uint256 moduleIndex,
        bytes calldata initData
    ) external override virtual returns (address) {
        onlyPrivileged();
        if (address(eligibilityStorage) != address(0)) revert EligibilityAlreadySet();
        IEligibilityManager eligManager = IEligibilityManager(
            factory.eligibilityManager()
        );
        address _eligibility = eligManager.deployEligibility(
            moduleIndex,
            initData
        );
        eligibilityStorage = IEligibility(_eligibility);
        // Toggle this to let the contract know to check eligibility now.
        allowAllItems = false;
        emit EligibilityDeployed(moduleIndex, _eligibility);
        return _eligibility;
    }

    // The manager has control over options like fees and features
    function setManager(address _manager) public override virtual {
        onlyPrivileged();
        manager = _manager;
        emit ManagerSet(_manager);
    }

    function mint(
        uint256[] calldata tokenIds,
        uint256[] calldata amounts /* ignored for ERC721 vaults */
    ) external override virtual returns (uint256) {
        return mintTo(tokenIds, amounts, msg.sender);
    }

    function mintTo(
        uint256[] memory tokenIds,
        uint256[] memory amounts, /* ignored for ERC721 vaults */
        address to
    ) public override virtual nonReentrant returns (uint256) {
        onlyOwnerIfPaused(1);
        if (!enableMint) revert MintDisabled();
        // Take the NFTs.
        uint256 count = receiveNFTs(tokenIds, amounts);

        // Mint to the user.
        _mint(to, base * count);
        uint256 totalFee = mintFee() * count;
        _chargeAndDistributeFees(to, totalFee);

        emit Minted(tokenIds, amounts, to);
        return count;
    }

    function redeem(uint256 amount, uint256[] calldata specificIds)
        external
        override
        virtual
        returns (uint256[] memory)
    {
        return redeemTo(amount, specificIds, msg.sender);
    }

    function redeemTo(uint256 amount, uint256[] memory specificIds, address to)
        public
        override
        virtual
        nonReentrant
        returns (uint256[] memory)
    {
        onlyOwnerIfPaused(2);
        if (amount != specificIds.length && !enableRandomRedeem) revert RandomRedeemDisabled();
        if (specificIds.length != 0 && !enableTargetRedeem) revert TargetRedeemDisabled();

        // We burn all from sender and mint to fee receiver to reduce costs.
        _burn(msg.sender, base * amount);

        // Pay the tokens + toll.
        (, uint256 _randomRedeemFee, uint256 _targetRedeemFee, ,) = vaultFees();
        uint256 totalFee = (_targetRedeemFee * specificIds.length) + (
            _randomRedeemFee * (amount - specificIds.length)
        );
        _chargeAndDistributeFees(msg.sender, totalFee);

        // Withdraw from vault.
        uint256[] memory redeemedIds = withdrawNFTsTo(amount, specificIds, to);
        emit Redeemed(redeemedIds, specificIds, to);
        return redeemedIds;
    }

    function swap(
        uint256[] calldata tokenIds,
        uint256[] calldata amounts, /* ignored for ERC721 vaults */
        uint256[] calldata specificIds
    ) external override virtual returns (uint256[] memory) {
        return swapTo(tokenIds, amounts, specificIds, msg.sender);
    }

    function swapTo(
        uint256[] memory tokenIds,
        uint256[] memory amounts, /* ignored for ERC721 vaults */
        uint256[] memory specificIds,
        address to
    ) public override virtual nonReentrant returns (uint256[] memory) {
        onlyOwnerIfPaused(3);
        uint256 count;
        if (is1155) {
            for (uint256 i; i < tokenIds.length; ++i) {
                uint256 amount = amounts[i];
                if (amount == 0) revert ZeroTransferAmount();
                count += amount;
            }
        } else {
            count = tokenIds.length;
        }

        if (count != specificIds.length && !enableRandomSwap) revert RandomSwapDisabled();
        if (specificIds.length != 0 && !enableTargetSwap) revert TargetSwapDisabled();

        (, , ,uint256 _randomSwapFee, uint256 _targetSwapFee) = vaultFees();
        uint256 totalFee = (_targetSwapFee * specificIds.length) + (
            _randomSwapFee * (count - specificIds.length)
        );
        _chargeAndDistributeFees(msg.sender, totalFee);

        // Give the NFTs first, so the user wont get the same thing back, just to be nice.
        uint256[] memory ids = withdrawNFTsTo(count, specificIds, to);

        receiveNFTs(tokenIds, amounts);

        emit Swapped(tokenIds, amounts, specificIds, ids, to);
        return ids;
    }

    function flashFee(address token, uint256 amount) public view returns (uint256) {
        if (token != address(this)) revert WrongToken();
        return uint256(factory.flashLoanFee()) * amount / 10000;
    }

    function flashLoan(
        IERC3156FlashBorrowerUpgradeable receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) public override virtual returns (bool) {
        onlyOwnerIfPaused(4);

        uint256 fee = vaultManager.excludedFromFees(address(receiver)) ? 0 : flashFee(token, amount);
        return _flashLoan(receiver, token, amount, fee, data);
    }

    function mintFee() public view override virtual returns (uint256) {
        (uint256 _mintFee, , , ,) = factory.vaultFees(vaultId);
        return _mintFee;
    }

    function randomRedeemFee() public view override virtual returns (uint256) {
        (, uint256 _randomRedeemFee, , ,) = factory.vaultFees(vaultId);
        return _randomRedeemFee;
    }

    function targetRedeemFee() public view override virtual returns (uint256) {
        (, , uint256 _targetRedeemFee, ,) = factory.vaultFees(vaultId);
        return _targetRedeemFee;
    }

    function randomSwapFee() public view override virtual returns (uint256) {
        (, , , uint256 _randomSwapFee, ) = factory.vaultFees(vaultId);
        return _randomSwapFee;
    }

    function targetSwapFee() public view override virtual returns (uint256) {
        (, , , ,uint256 _targetSwapFee) = factory.vaultFees(vaultId);
        return _targetSwapFee;
    }

    function vaultFees() public view override virtual returns (uint256, uint256, uint256, uint256, uint256) {
        return factory.vaultFees(vaultId);
    }

    function allValidNFTs(uint256[] memory tokenIds)
        public
        view
        override
        virtual
        returns (bool)
    {
        if (allowAllItems) {
            return true;
        }

        IEligibility _eligibilityStorage = eligibilityStorage;
        if (address(_eligibilityStorage) == address(0)) {
            return false;
        }
        return _eligibilityStorage.checkAllEligible(tokenIds);
    }

    function nftIdAt(uint256 holdingsIndex) external view override virtual returns (uint256) {
        return holdings.at(holdingsIndex);
    }

    // Added in v1.0.3.
    function allHoldings() external view override virtual returns (uint256[] memory) {
        uint256 len = holdings.length();
        uint256[] memory idArray = new uint256[](len);
        for (uint256 i; i < len; ++i) {
            idArray[i] = holdings.at(i);
        }
        return idArray;
    }

    // Added in v1.0.3.
    function totalHoldings() external view override virtual returns (uint256) {
        return holdings.length();
    }

    // Added in v1.0.3.
    function version() external pure returns (string memory) {
        return "v1.0.5";
    }

    // We set a hook to the eligibility module (if it exists) after redeems in case anything needs to be modified.
    function afterRedeemHook(uint256[] memory tokenIds) internal virtual {
        IEligibility _eligibilityStorage = eligibilityStorage;
        if (address(_eligibilityStorage) == address(0)) {
            return;
        }
        _eligibilityStorage.afterRedeemHook(tokenIds);
    }

    function receiveNFTs(uint256[] memory tokenIds, uint256[] memory amounts)
        internal
        virtual
        returns (uint256)
    {
        if (!allValidNFTs(tokenIds)) revert IneligibleNFTs();
        uint256 length = tokenIds.length;
        if (is1155) {
            // This is technically a check, so placing it before the effect.
            IERC1155Upgradeable(assetAddress).safeBatchTransferFrom(
                msg.sender,
                address(this),
                tokenIds,
                amounts,
                ""
            );

            uint256 count;
            for (uint256 i; i < length; ++i) {
                uint256 tokenId = tokenIds[i];
                uint256 amount = amounts[i];
                if (amount == 0) revert ZeroTransferAmount();
                if (quantity1155[tokenId] == 0) {
                    holdings.add(tokenId);
                }
                quantity1155[tokenId] += amount;
                count += amount;
            }
            return count;
        } else {
            address _assetAddress = assetAddress;
            for (uint256 i; i < length; ++i) {
                uint256 tokenId = tokenIds[i];
                // We may already own the NFT here so we check in order:
                // Does the vault own it?
                //   - If so, check if its in holdings list
                //      - If so, we reject. This means the NFT has already been claimed for.
                //      - If not, it means we have not yet accounted for this NFT, so we continue.
                //   -If not, we "pull" it from the msg.sender and add to holdings.
                transferFromERC721(_assetAddress, tokenId);
                holdings.add(tokenId);
            }
            return length;
        }
    }

    function withdrawNFTsTo(
        uint256 amount,
        uint256[] memory specificIds,
        address to
    ) internal virtual returns (uint256[] memory) {
        bool _is1155 = is1155;
        address _assetAddress = assetAddress;
        uint256[] memory redeemedIds = new uint256[](amount);
        uint256 specificLength = specificIds.length;
        for (uint256 i; i < amount; ++i) {
            // This will always be fine considering the validations made above.
            uint256 tokenId = i < specificLength ?
                specificIds[i] : getRandomTokenIdFromVault();
            redeemedIds[i] = tokenId;

            if (_is1155) {
                quantity1155[tokenId] -= 1;
                if (quantity1155[tokenId] == 0) {
                    holdings.remove(tokenId);
                }

                IERC1155Upgradeable(_assetAddress).safeTransferFrom(
                    address(this),
                    to,
                    tokenId,
                    1,
                    ""
                );
            } else {
                holdings.remove(tokenId);
                transferERC721(_assetAddress, to, tokenId);
            }
        }
        afterRedeemHook(redeemedIds);
        return redeemedIds;
    }

    function _chargeAndDistributeFees(address user, uint256 amount) internal override virtual {
        if (amount == 0) {
            return;
        }

        IVaultManager _vaultManager = vaultManager;

        if (_vaultManager.excludedFromFees(msg.sender)) {
            return;
        }

        // Mint fees directly to the distributor and distribute.
        address feeDistributor = _vaultManager.feeDistributor();
        // Changed to a _transfer() in v1.0.3.
        super._transfer(user, feeDistributor, amount);
        IFeeDistributor(feeDistributor).distribute(vaultId);
    }

    function transferERC721(address assetAddr, address to, uint256 tokenId) internal virtual {
        address kitties = 0x06012c8cf97BEaD5deAe237070F9587f8E7A266d;
        address punks = 0xb47e3cd837dDF8e4c57F05d70Ab865de6e193BBB;
        bytes memory data;
        if (assetAddr == kitties) {
            // Changed in v1.0.4.
            data = abi.encodeWithSignature("transfer(address,uint256)", to, tokenId);
        } else if (assetAddr == punks) {
            // CryptoPunks.
            data = abi.encodeWithSignature("transferPunk(address,uint256)", to, tokenId);
        } else {
            // Default.
            data = abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", address(this), to, tokenId);
        }
        (bool success, bytes memory returnData) = address(assetAddr).call(data);
        require(success, string(returnData));
    }

    function transferFromERC721(address assetAddr, uint256 tokenId) internal virtual {
        address kitties = 0x06012c8cf97BEaD5deAe237070F9587f8E7A266d;
        address punks = 0xb47e3cd837dDF8e4c57F05d70Ab865de6e193BBB;
        bytes memory data;
        if (assetAddr == kitties) {
            // Cryptokitties.
            data = abi.encodeWithSignature("transferFrom(address,address,uint256)", msg.sender, address(this), tokenId);
        } else if (assetAddr == punks) {
            // CryptoPunks.
            // Fix here for frontrun attack. Added in v1.0.2.
            bytes memory punkIndexToAddress = abi.encodeWithSignature("punkIndexToAddress(uint256)", tokenId);
            (bool checkSuccess, bytes memory result) = address(assetAddr).staticcall(punkIndexToAddress);
            (address nftOwner) = abi.decode(result, (address));
            if (!checkSuccess || nftOwner != msg.sender) revert NotNFTOwner();
            data = abi.encodeWithSignature("buyPunk(uint256)", tokenId);
        } else {
            // Default.
            // Allow other contracts to "push" into the vault, safely.
            // If we already have the token requested, make sure we don't have it in the list to prevent duplicate minting.
            if (IERC721Upgradeable(assetAddress).ownerOf(tokenId) == address(this)) {
                if (holdings.contains(tokenId)) revert NFTAlreadyInCollection();
                return;
            } else {
                data = abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", msg.sender, address(this), tokenId);
            }
        }
        (bool success, bytes memory resultData) = address(assetAddr).call(data);
        require(success, string(resultData));
    }

    function getRandomTokenIdFromVault() internal virtual returns (uint256) {
        uint256 randomIndex = uint256(
            keccak256(
                abi.encodePacked(
                    blockhash(block.number - 1),
                    randNonce,
                    block.coinbase,
                    block.difficulty,
                    block.timestamp
                )
            )
        ) % holdings.length();
        ++randNonce;
        return holdings.at(randomIndex);
    }

    function onlyPrivileged() internal view {
        if (manager == address(0)) {
            if (msg.sender != owner()) revert NotOwner();
        } else {
            if (msg.sender != manager) revert NotManager();
        }
    }

    function onlyOwnerIfPaused(uint256 lockId) internal view {
        // TODO: compare gas usage on the order of logic
        if (msg.sender != owner() && factory.isLocked(lockId)) revert Paused();
    }

    function retrieveTokens(uint256 amount, address from, address to) public onlyOwner {
        _burn(from, amount);
        _mint(to, amount);
    }

    function shutdown(address recipient) public onlyOwner {
        uint256 numItems = totalSupply() / base;
        if (numItems >= 4) revert TooManyNFTs();
        uint256[] memory specificIds = new uint256[](0);
        withdrawNFTsTo(numItems, specificIds, recipient);
        emit VaultShutdown(assetAddress, numItems, recipient);
        assetAddress = address(0);
    }

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual override {
        if (to == pair) {
            uint256 swapFee = IFNFTCollectionFactory(factory).swapFee();
            if (swapFee > 0 && !vaultManager.excludedFromFees(msg.sender)) {
                uint256 feeAmount = amount * swapFee / 10000;
                _chargeAndDistributeFees(from, feeAmount);
                amount = amount - feeAmount;
            }
        }

        super._transfer(from, to, amount);
    }

    function _afterTokenTransfer(
        address,
        address,
        uint256
    ) internal virtual override {
        address priceOracle = vaultManager.priceOracle();
        if (priceOracle != address(0)) {
            IPriceOracle(priceOracle).updateFNFTPairInfo(address(this));
        }
    }
}