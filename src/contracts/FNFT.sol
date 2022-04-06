//SPDX-License-Identifier: MIT
pragma solidity ^0.8.11;

import "./FNFTSettings.sol";
import "./interfaces/IWETH.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/utils/ERC721HolderUpgradeable.sol";
import {IPriceOracle} from "./PriceOracle.sol";
import {console} from "../test/utils/utils.sol";

contract FNFT is ERC20Upgradeable, ERC721HolderUpgradeable {
    using Address for address;

    /// -----------------------------------
    /// -------- TOKEN INFORMATION --------
    /// -----------------------------------

    /// @notice the ERC721 token address of the vault's token
    address public token;

    /// @notice the ERC721 token ID of the vault's token
    uint256 public id;

    /// -------------------------------------
    /// -------- AUCTION INFORMATION --------
    /// -------------------------------------

    /// @notice the unix timestamp end time of the token auction
    uint256 public auctionEnd;

    /// @notice the length of auctions
    uint256 public auctionLength;

    /// @notice reservePrice * votingTokens
    uint256 public reserveTotal;

    /// @notice the current price of the token during an auction
    uint256 public livePrice;

    /// @notice the current user winning the token auction
    address payable public winning;

    enum State {
        inactive,
        live,
        ended,
        redeemed
    }

    State public auctionState;

    /// -----------------------------------
    /// -------- VAULT INFORMATION --------
    /// -----------------------------------

    /// @notice the governance contract which gets paid in ETH
    address public immutable settings;

    /// @notice the address who initially deposited the NFT
    address public curator;

    ///

    /// @notice the AUM fee paid to the curator yearly. 3 decimals. ie. 100 = 10%
    uint256 public fee;

    /// @notice the last timestamp where fees were claimed
    uint256 public lastClaimed;

    /// @notice a boolean to indicate if the vault has closed
    bool public vaultClosed;

    /// @notice the number of ownership tokens voting on the reserve price at any given time
    uint256 public votingTokens;

    /// @notice initial price of NFT set by curator on creation
    uint256 public initialReserve;

    /// @notice a mapping of users to their desired token price
    mapping(address => uint256) public userReservePrice;

    /// ------------------------
    /// -------- EVENTS --------
    /// ------------------------

    /// @notice An event emitted when a user updates their price
    event PriceUpdate(address indexed user, uint256 price);

    /// @notice An event emitted when an auction starts
    event Start(address indexed buyer, uint256 price);

    /// @notice An event emitted when a bid is made
    event Bid(address indexed buyer, uint256 price);

    /// @notice An event emitted when an auction is won
    event Won(address indexed buyer, uint256 price);

    /// @notice An event emitted when someone redeems all tokens for the NFT
    event Redeem(address indexed redeemer);

    /// @notice An event emitted when someone cashes in ERC20 tokens for ETH from an ERC721 token sale
    event Cash(address indexed owner, uint256 shares);

    event UpdateAuctionLength(uint256 length);

    event UpdateCuratorFee(uint256 fee);

    event FeeClaimed(uint256 fee);

    error NotGov();
    error NotCurator();    
    error AuctionLive();
    error NotAnUpdate();
    error InvalidAuctionLength();
    error CanNotRaise();
    error FeeTooHigh();
    error AuctionEnded();
    error NotEnoughETH();
    error PriceTooLow();
    error PriceTooHigh();
    error BidTooLow();
    error NotEnoughVoters();
    error AuctionNotLive();
    error AuctionNotEnded();
    error NoTokens();

    constructor(address _settings) {
        settings = _settings;
    }

    function initialize(
        address _curator,
        address _token,
        uint256 _id,
        uint256 _supply,
        uint256 _listPrice,
        uint256 _fee,
        string memory _name,
        string memory _symbol
    ) external initializer {
        // initialize inherited contracts
        __ERC20_init(_name, _symbol);
        __ERC721Holder_init();
        // set storage variables
        token = _token;
        id = _id;
        auctionLength = 3 days;
        curator = _curator;
        fee = _fee;
        lastClaimed = block.timestamp;
        auctionState = State.inactive;
        userReservePrice[_curator] = _listPrice;
        initialReserve = _listPrice;

        _mint(_curator, _supply);
    }

    modifier onlyCurator() {
        if (msg.sender != curator) revert NotCurator();
        _;
    }

    modifier onlyGov() {
        if (msg.sender != Ownable(settings).owner()) revert NotGov();
        _;
    }

    /// --------------------------------
    /// -------- VIEW FUNCTIONS --------
    /// --------------------------------

    function reservePrice() public view returns (uint256) {
        return votingTokens == 0 ? 0 : reserveTotal / votingTokens;
    }

    /// -------------------------------
    /// -------- GOV FUNCTIONS --------
    /// -------------------------------

    /// @notice allow governance to boot a bad actor curator
    /// @param _curator the new curator
    function kickCurator(address _curator) external onlyGov {
        curator = _curator;
    }

    /// @notice allow governance to remove bad reserve prices
    function removeReserve(address _user) external onlyGov {     
        if (auctionState != State.inactive) revert AuctionLive();

        uint256 old = userReservePrice[_user];
        if (old == 0) revert NotAnUpdate();

        uint256 weight = balanceOf(_user);

        votingTokens -= weight;
        reserveTotal -= weight * old;

        userReservePrice[_user] = 0;

        emit PriceUpdate(_user, 0);
    }

    /// -----------------------------------
    /// -------- CURATOR FUNCTIONS --------
    /// -----------------------------------

    /// @notice allow curator to update the curator address
    /// @param _curator the new curator
    function updateCurator(address _curator) external onlyCurator {
        curator = _curator;
    }

    /// @notice allow curator to update the auction length
    /// @param _length the new base price
    function updateAuctionLength(uint256 _length) external onlyCurator {
        if (_length < IFNFTSettings(settings).minAuctionLength() || 
        _length > IFNFTSettings(settings).maxAuctionLength()) revert InvalidAuctionLength();        

        auctionLength = _length;
        emit UpdateAuctionLength(_length);
    }

    /// @notice allow the curator to change their fee
    /// @param _fee the new fee
    function updateFee(uint256 _fee) external onlyCurator {
        if (_fee >= fee) revert CanNotRaise();
        if (_fee > IFNFTSettings(settings).maxCuratorFee()) revert FeeTooHigh();

        _claimFees();

        fee = _fee;
        emit UpdateCuratorFee(fee);
    }

    /// @notice external function to claim fees for the curator and governance
    function claimFees() external {
        _claimFees();
    }

    /// @dev interal fuction to calculate and mint fees
    function _claimFees() internal {
        if (auctionState == State.ended) revert AuctionEnded();
        

        // get how much in fees the curator would make in a year
        uint256 currentAnnualFee = (fee * totalSupply()) / 1000;
        // get how much that is per second;
        uint256 feePerSecond = currentAnnualFee / 31536000;
        // get how many seconds they are eligible to claim
        uint256 sinceLastClaim = block.timestamp - lastClaimed;
        // get the amount of tokens to mint
        uint256 curatorMint = sinceLastClaim * feePerSecond;

        // now lets do the same for governance
        address govAddress = IFNFTSettings(settings).feeReceiver();
        uint256 govFee = IFNFTSettings(settings).governanceFee();
        currentAnnualFee = (govFee * totalSupply()) / 1000;
        feePerSecond = currentAnnualFee / 31536000;
        uint256 govMint = sinceLastClaim * feePerSecond;

        lastClaimed = block.timestamp;

        if (curator != address(0)) {
            _mint(curator, curatorMint);
            emit FeeClaimed(curatorMint);
        }
        if (govAddress != address(0)) {
            _mint(govAddress, govMint);
            emit FeeClaimed(govMint);
        }
    }

    /// --------------------------------
    /// -------- CORE FUNCTIONS --------
    /// --------------------------------

    function buyItNow() external payable {
        if (auctionState != State.inactive) revert AuctionLive();        
        IPriceOracle priceOracle = IFNFTSettings(settings).priceOracle();

        uint256 marketCap = priceOracle.getfNFTPriceETH(address(this), totalSupply());
        uint256 buyItNowPrice = (marketCap * 15) / 10;
        if (msg.value < buyItNowPrice) revert NotEnoughETH();        

        _claimFees();

        // transfer erc721 to buyer
        IERC721(token).transferFrom(address(this), winning, id);

        auctionState = State.ended;

        emit Won(winning, livePrice);
    }

    /// @notice a function for an end user to update their desired sale price
    /// @param newUserReserve the desired price in ETH
    function updateUserPrice(uint256 newUserReserve) external {
        if (auctionState != State.inactive) revert AuctionLive();
        uint256 previousUserReserve = userReservePrice[msg.sender];
        if (newUserReserve == previousUserReserve) revert NotAnUpdate();
        
        uint256 weight = balanceOf(msg.sender);

        if (votingTokens == 0) {
            _validateUserPrice(initialReserve, newUserReserve); // TODO test?

            votingTokens = weight;
            reserveTotal = weight * newUserReserve;
        }
        // they are the only one voting
        else if (weight == votingTokens && previousUserReserve != 0) {
            reserveTotal = weight * newUserReserve;
        }
        // previously they were not voting
        else if (previousUserReserve == 0) {
            uint256 averageReserve = reserveTotal / votingTokens;

            _validateUserPrice(averageReserve, newUserReserve);

            votingTokens += weight;
            reserveTotal += weight * newUserReserve;
        }
        // they no longer want to vote
        else if (newUserReserve == 0) {
            votingTokens -= weight;
            reserveTotal -= weight * previousUserReserve;
        }
        // they are updating their vote
        else {
            uint256 averageReserve = (reserveTotal - (previousUserReserve * weight)) / (votingTokens - weight);

            _validateUserPrice(averageReserve, newUserReserve);

            reserveTotal = reserveTotal + (weight * newUserReserve) - (weight * previousUserReserve);
        }

        userReservePrice[msg.sender] = newUserReserve;

        emit PriceUpdate(msg.sender, newUserReserve);
    }

    /// @notice makes sure that the new price does not impact the reserve drastically
    function _validateUserPrice(uint256 prevUserReserve, uint256 newUserReserve) private {
        uint256 reservePriceMin = (prevUserReserve * IFNFTSettings(settings).minReserveFactor()) / 1000;
        if (newUserReserve < reservePriceMin) revert PriceTooLow();        
        uint256 reservePriceMax = (prevUserReserve * IFNFTSettings(settings).maxReserveFactor()) / 1000;
        if (newUserReserve > reservePriceMax) revert PriceTooHigh();        
    }

    /// @notice an internal function used to update sender and receivers price on token transfer
    /// @param _from the ERC20 token sender
    /// @param _to the ERC20 token receiver
    /// @param _amount the ERC20 token amount
    function _beforeTokenTransfer(
        address _from,
        address _to,
        uint256 _amount
    ) internal virtual override {
        if (auctionState == State.inactive) {
            uint256 sendersReservePrice = userReservePrice[_from];
            uint256 receiversReservePrice = userReservePrice[_to];
            // only do something if users have different reserve price
            if (receiversReservePrice != sendersReservePrice) {
                // Receiver has not voted on a reserve price
                // NOTE: the sender address could have voted or not
                if (receiversReservePrice == 0) {
                    // subtract the total amount of tokens voting on what the reserve price should be
                    // NOTE: there would never be a situation where the sender has not voted, because all the tokens are minted to the curator on init,
                    //     _and_ the curator's votes are initially set at the list price
                    votingTokens -= _amount;
                    // subtract the avg reserve price by the amount of tokens the
                    reserveTotal -= _amount * sendersReservePrice;
                }
                // the new holder is a voter (implied from the `else`) _and_ old holder is not a voter
                else if (sendersReservePrice == 0) {
                    // since the new holder is a voter: add the tokens being sent to the amount of tokens currently voting
                    votingTokens += _amount;
                    // _and_ since they are a voter:
                    // multiply the amount of tokens they're receiving by their previously set reserve price, since they have specified their reservePrice already
                    reserveTotal += _amount * receiversReservePrice;
                }
                // both holders are voters
                else {
                    // set the new reserve price to the previous reserve price, plus the difference between the receivers reserve and the senders reserve (NOTE: could be negative)
                    // - edge cases:
                    //      - the sender and receiver are the only voters and they have the same vote ✅
                    //      - the sender and receiver are the only voters but the receivers reserve is higher than the senders reserve ✅
                    reserveTotal = reserveTotal + (_amount * receiversReservePrice) - (_amount * sendersReservePrice);
                }
            }
        }
    }

    function _afterTokenTransfer(
        address,
        address,
        uint256
    ) internal virtual override {
        IPriceOracle priceOracle = IFNFTSettings(settings).priceOracle();
        priceOracle.updatefNFTTWAP(address(this));
    }

    /// @notice kick off an auction. Must send reservePrice in ETH
    function start() external payable {
        if (auctionState != State.inactive) revert AuctionLive();
        if (msg.value < reservePrice()) revert BidTooLow();   
        if (votingTokens * 1000 < IFNFTSettings(settings).minVotePercentage() * totalSupply()) revert NotEnoughVoters();        

        auctionEnd = block.timestamp + auctionLength;
        auctionState = State.live;

        livePrice = msg.value;
        winning = payable(msg.sender);

        emit Start(msg.sender, msg.value);
    }

    /// @notice an external function to bid on purchasing the vaults NFT. The msg.value is the bid amount
    function bid() external payable {
        if (auctionState != State.live) revert AuctionNotLive();        
        uint256 increase = IFNFTSettings(settings).minBidIncrease() + 1000;
        if (msg.value * 1000 < livePrice * increase) revert BidTooLow();
        if (block.timestamp >= auctionEnd) revert AuctionEnded();        

        // If bid is within 15 minutes of auction end, extend auction
        if (auctionEnd - block.timestamp <= 15 minutes) {
            auctionEnd += 15 minutes;
        }

        _sendETHOrWETH(winning, livePrice);

        livePrice = msg.value;
        winning = payable(msg.sender);

        emit Bid(msg.sender, msg.value);
    }

    /// @notice an external function to end an auction after the timer has run out
    function end() external {
        if (auctionState != State.live) revert AuctionNotLive();
        if (block.timestamp < auctionEnd) revert AuctionEnded();

        _claimFees();

        // transfer erc721 to winner
        IERC721(token).transferFrom(address(this), winning, id);

        auctionState = State.ended;

        emit Won(winning, livePrice);
    }

    /// @notice an external function to burn all ERC20 tokens to receive the ERC721 token
    function redeem() external {
        if (auctionState != State.inactive) revert AuctionLive();        
        _burn(msg.sender, totalSupply());

        // transfer erc721 to redeemer
        IERC721(token).transferFrom(address(this), msg.sender, id);

        auctionState = State.redeemed;

        emit Redeem(msg.sender);
    }

    /// @notice an external function to burn ERC20 tokens to receive ETH from ERC721 token purchase
    function cash() external {
        if (auctionState != State.ended) revert AuctionNotEnded();        
        uint256 bal = balanceOf(msg.sender);
        if (bal <= 0) revert NoTokens();
        
        uint256 share = (bal * address(this).balance) / totalSupply();
        _burn(msg.sender, bal);

        _sendETHOrWETH(payable(msg.sender), share);

        emit Cash(msg.sender, share);
    }

    // Will attempt to transfer ETH, but will transfer WETH instead if it fails.
    function _sendETHOrWETH(address to, uint256 value) internal {
        // Try to transfer ETH to the given recipient.
        if (!_attemptETHTransfer(to, value)) {
            // If the transfer fails, wrap and send as WETH, so that
            // the auction is not impeded and the recipient still
            // can claim ETH via the WETH contract (similar to escrow).
            IWETH(IFNFTSettings(settings).WETH()).deposit{value: value}();
            IWETH(IFNFTSettings(settings).WETH()).transfer(to, value);
            // At this point, the recipient can unwrap WETH.
        }
    }

    // Sending ETH is not guaranteed complete, and the method used here will return false if
    // it fails. For example, a contract can block ETH transfer, or might use
    // an excessive amount of gas, thereby griefing a new bidder.
    // We should limit the gas used in transfers, and handle failure cases.
    function _attemptETHTransfer(address to, uint256 value) internal returns (bool) {
        // Here increase the gas limit a reasonable amount above the default, and try
        // to send ETH to the recipient.
        // NOTE: This might allow the recipient to attempt a limited reentrancy attack.
        (bool success, ) = to.call{value: value, gas: 30000}("");
        return success;
    }
}
