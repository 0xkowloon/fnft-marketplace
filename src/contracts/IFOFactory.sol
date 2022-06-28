//SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./IFO.sol";
import "./interfaces/IIFOFactory.sol";
import "./proxy/BeaconUpgradeable.sol";
import "./proxy/BeaconProxy.sol";

contract IFOFactory is IIFOFactory, OwnableUpgradeable, PausableUpgradeable, BeaconUpgradeable {
    /// @notice the mapping of fNFT to IFO address
    mapping(address => address) public override getIFO;

    uint256 public override minimumDuration;
    uint256 public override maximumDuration;
    uint256 public override governanceFee;
    /// @notice 10% fee is max
    uint256 public constant MAX_GOV_FEE = 1000;
    address public override creatorUtilityContract;
    /// @notice the boolean whether creator should have access to the creator's fNFT shares after IFO
    bool public override creatorIFOLock;
    /// @notice the address who receives ifo fees
    address payable public override feeReceiver;

    function __IFOFactory_init() external override initializer {
        __Ownable_init();
        __Pausable_init();
        __BeaconUpgradeable__init(address(new IFO()));

        minimumDuration = 86400; // 1 day;
        feeReceiver = payable(msg.sender);
        maximumDuration = 7776000; // 90 days;
        governanceFee = 200;
    }

    /// @notice the function to create an IFO
    /// @param _FNFT the ERC20 token address of the FNFT
    /// @param _amountForSale the amount of FNFT for sale in IFO
    /// @param _price the price of each FNFT token
    /// @param _cap the maximum amount an account can buy
    /// @param _allowWhitelisting if IFO should be governed by whitelists
    /// @return IFO address
    function create(
        address _FNFT,
        uint256 _amountForSale,
        uint256 _price,
        uint256 _cap,
        uint256 _duration,
        bool _allowWhitelisting
    ) external override whenNotPaused returns (address) {
        bytes memory _initializationCalldata = abi.encodeWithSelector(
            IFO.__IFO_init.selector,
            msg.sender,
            _FNFT,
            _amountForSale,
            _price,
            _cap,
            _duration,
            _allowWhitelisting
        );

        address _IFO = address(new BeaconProxy(address(this), _initializationCalldata));
        getIFO[_FNFT] = _IFO;

        IERC20(_FNFT).transferFrom(msg.sender, _IFO, IERC20(_FNFT).balanceOf(msg.sender));

        emit IFOCreated(_IFO, _FNFT, _amountForSale, _price, _cap, _duration, _allowWhitelisting);

        return _IFO;
    }

    function pause() external override onlyOwner {
        _pause();
    }

    function unpause() external override onlyOwner {
        _unpause();
    }

    function setCreatorIFOLock(bool _lock) external override onlyOwner {
        emit UpdateCreatorIFOLock(creatorIFOLock, _lock);

        creatorIFOLock = _lock;
    }

    function setMinimumDuration(uint256 _blocks) external override onlyOwner {
        if (_blocks > maximumDuration) revert InvalidDuration();

        emit UpdateMinimumDuration(minimumDuration, _blocks);

        minimumDuration = _blocks;
    }

    function setMaximumDuration(uint256 _blocks) external override onlyOwner {
        if (minimumDuration > _blocks) revert InvalidDuration();

        emit UpdateMaximumDuration(maximumDuration, _blocks);

        maximumDuration = _blocks;
    }

    function setCreatorUtilityContract(address _utility) external override onlyOwner {
        emit UpdateCreatorUtilityContract(creatorUtilityContract, _utility);

        creatorUtilityContract = _utility;
    }

    function setGovernanceFee(uint256 _fee) external override onlyOwner {
        if (_fee > MAX_GOV_FEE) revert FeeTooHigh();

        emit GovernanceFeeUpdated(governanceFee, _fee);

        governanceFee = _fee;
    }

    function setFeeReceiver(address payable _receiver) external override onlyOwner {
        if (_receiver == address(0)) revert ZeroAddressDisallowed();

        emit UpdateFeeReceiver(feeReceiver, _receiver);

        feeReceiver = _receiver;
    }
}
