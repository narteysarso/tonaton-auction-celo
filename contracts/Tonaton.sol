//SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/**
 * A time-based auction marketplace. Think of it as ebay for blockchain where individuales
 * can create auctions for their various items, set an auction ellapse time, and a minimum bid amount
 * for their auction.
 * The auction charges 10 gwei for each auction which is deducted at the end of an auction when
 * there is successful highest bidder.
 */
contract Tonaton is IERC721Receiver {
    using Counters for Counters.Counter;
    event AuctionCreated(
        uint256 indexed auction,
        address indexed owner,
        address nft,
        uint256 tokenId,
        uint256 leastBid
    );
    event AuctionStarted(uint256 indexed auction, uint256 startedTime);
    event BidPlaced(
        uint256 indexed auction,
        address indexed bidder,
        uint256 amount
    );
    event AuctionEnded(uint256 indexed auction, uint256 endTime);

    address private _admin;
    uint256 fee = 10 gwei;
    uint256 private _chargedFees;
    mapping(uint256 => Auction) public auctions;
    Counters.Counter public _auctionCounter;

    struct Auction {
        address seller;
        address nft;
        uint256 tokenId;
        uint256 leastBid;
        uint256 highestBid;
        address highestBidder;
        uint256 startTime;
        uint256 endTime;
        mapping(address => uint256) bids;
    }

    modifier onlyOwner(uint256 auctionIndex) {
        require(
            msg.sender == auctions[auctionIndex].seller,
            "You do not own this auction"
        );
        _;
    }

    modifier auctionHasStarted(uint256 auctionIndex) {
        require(
            auctionIndex <= _auctionCounter.current(),
            "Index out of range"
        );
        Auction storage _auction = auctions[auctionIndex];
        require(
            _auction.startTime > 0 && (_auction.startTime < block.timestamp),
            "Auction has not started"
        );
        _;
    }

    modifier onlyAdmin() {
        require(msg.sender == _admin, "You are unauthorized for this action");
        _;
    }

    constructor() {
        //set contract admin
        _admin = msg.sender;
    }

    /**
     *@dev create an auction for any nft
     * @param _nft address of the nft contract
     * @param _tokenId ID of the nft on the contract
     * @param _leastBid the minimum bid for the auction
     */
    function createAuction(
        address _nft,
        uint256 _tokenId,
        uint256 _leastBid
    ) external {
        _auctionCounter.increment();
        require(_nft != address(0), "Invalid contract address");
        require(
            IERC721(_nft).ownerOf(_tokenId) == msg.sender &&
                IERC721(_nft).getApproved(_tokenId) == address(this),
            "Invalid caller or contract hasn't been approved"
        );
        IERC721(_nft).transferFrom(msg.sender, address(this), _tokenId);

        Auction storage _auction = auctions[_auctionCounter.current()];
        _auction.seller = msg.sender;
        _auction.nft = _nft;
        _auction.tokenId = _tokenId;
        _auction.leastBid = _leastBid;

        emit AuctionCreated(
            _auctionCounter.current(),
            msg.sender,
            _nft,
            _tokenId,
            _leastBid
        );
    }

    /**
     * start an auctions if you are the one who created it
     * @param index auction ID
     * @param endTime timestamp for when auction should end
     */
    function start(uint256 index, uint256 endTime) external onlyOwner(index) {
        Auction storage _auction = auctions[index];
        require(
            _auction.startTime == 0 && _auction.endTime == 0,
            "Auction has already started"
        );
        _auction.startTime = block.timestamp;
        _auction.endTime = block.timestamp + endTime;
        emit AuctionStarted(index, _auction.startTime);
    }

    /**
     * bid in an auction
     * @param index auction ID
     */
    function bid(uint256 index) external payable auctionHasStarted(index) {
        Auction storage _auction = auctions[index];
        require(
            msg.value > _auction.highestBid && msg.value >= _auction.leastBid,
            "Amount is too small"
        );
        require(
            msg.sender != _auction.highestBidder,
            "You can't outbid yourself"
        );
        require(_auction.endTime > block.timestamp, "Auction is over");
        if (msg.value > _auction.highestBid) {
            _auction.highestBid = msg.value;
            _auction.highestBidder = msg.sender;
        }

        _auction.bids[msg.sender] += msg.value;
        emit BidPlaced(index, msg.sender, msg.value);
    }

    /**
     * End auction, send nft to highest bidder, pay charges and
     * withdraw highest bid amount if you are the owner
     * @param index auction ID
     */
    function end(uint256 index)
        external
        payable
        onlyOwner(index)
        auctionHasStarted(index)
    {
        Auction storage _auction = auctions[index];

        require(block.timestamp >= _auction.endTime, "Auction time has not elapsed");

        if(_auction.highestBidder == address(0)){
             IERC721(_auction.nft).safeTransferFrom(address(this), _auction.seller, _auction.tokenId);
             emit AuctionEnded(index, block.timestamp);
             return;
        }

        address winner = _auction.highestBidder;

        //deduct auction fee
        uint256 amount = _auction.highestBid - fee;
        _chargedFees += fee;

        IERC721(_auction.nft).safeTransferFrom(address(this), winner, _auction.tokenId);
        
        _auction.highestBid = 0;

        (bool sent, ) = payable(_auction.seller).call{value: amount}("");

        require(sent, "Failed to transfer amount");

        emit AuctionEnded(index, block.timestamp);
    }

    /**
     * withdraw bid funds.
     * @param index auction ID
     */
    function withdraw(uint256 index) external payable {
        Auction storage auction = auctions[index];
        require(msg.sender != address(0), "Invalid address");
        require(auction.bids[msg.sender] > 0, "No bid");
        require(
            msg.sender != auction.highestBidder,
            "Highest bidder cannot withdraw"
        );

        uint256 amount = auction.bids[msg.sender];
        auction.bids[msg.sender] = 0;

        (bool sent, ) = payable(msg.sender).call{value: amount}("");

        require(sent, "Failed to send amount");
    }

    ///@dev withdraw fees charged for successful auctions
    function withdrawChargedFees() external onlyAdmin {
        uint amount = _chargedFees;
        _chargedFees = 0;
        (bool sent,) = msg.sender.call{value: amount}("");
        require(sent, "Failed to send amount");
    }

    function getChargedFees() public view returns (uint256) {
        return _chargedFees;
    }

    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return bytes4(this.onERC721Received.selector);
    }

}
