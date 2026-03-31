// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract Marketplace is ReentrancyGuard, ERC721Holder {
    address payable public feeAccount;
    uint256 public feePercent; // Out of 1000 (e.g., 25 = 2.5%)

    struct Listing {
        uint256 price;
        address payable seller;
    }

    struct Offer {
        uint256 price;
    }

    // nftContract => tokenId => Listing (Only 1 active listing per specific NFT possible from Escrow)
    mapping(address => mapping(uint256 => Listing)) public listings;

    // nftContract => tokenId => offerer => Offer
    mapping(address => mapping(uint256 => mapping(address => Offer))) public itemOffers;

    // nftContract => offerer => Offer
    mapping(address => mapping(address => Offer)) public collectionOffers;

    // --- Events ---
    event Listed(address indexed nftContract, uint256 indexed tokenId, uint256 price, address indexed seller);
    event Sold(address indexed nftContract, uint256 indexed tokenId, uint256 price, address seller, address indexed buyer);
    event ListingCanceled(address indexed nftContract, uint256 indexed tokenId, address indexed seller);
    
    event ItemOfferMade(address indexed nftContract, uint256 indexed tokenId, uint256 price, address indexed offerer);
    event ItemOfferAccepted(address indexed nftContract, uint256 indexed tokenId, uint256 price, address offerer, address indexed seller);
    event ItemOfferCanceled(address indexed nftContract, uint256 indexed tokenId, address indexed offerer);

    event CollectionOfferMade(address indexed nftContract, uint256 price, address indexed offerer);
    event CollectionOfferAccepted(address indexed nftContract, uint256 indexed tokenId, uint256 price, address offerer, address indexed seller);
    event CollectionOfferCanceled(address indexed nftContract, address indexed offerer);


    constructor(uint256 _feePercent) {
        require(_feePercent <= 100, "Fee too high"); // Max fee is 100/1000 (10%)
        feePercent = _feePercent;
        feeAccount = payable(msg.sender);
    }

    // --- 1. Direct Listings (Escrow) ---

    /**
     * @notice Lists an NFT by transferring it into the Marketplace Escrow.
     */
    function listNFT(address _nftContract, uint256 _tokenId, uint256 _price) external nonReentrant {
        require(_price > 0, "Price must be > 0");
        require(listings[_nftContract][_tokenId].price == 0, "Already listed");

        listings[_nftContract][_tokenId] = Listing(_price, payable(msg.sender));

        // Transfer NFT into Escrow
        IERC721(_nftContract).safeTransferFrom(msg.sender, address(this), _tokenId);

        emit Listed(_nftContract, _tokenId, _price, msg.sender);
    }

    /**
     * @notice Buy a listed NFT from Escrow.
     */
    function buyNFT(address _nftContract, uint256 _tokenId) external payable nonReentrant {
        Listing memory listing = listings[_nftContract][_tokenId];
        require(listing.price > 0, "Not listed");
        require(msg.value >= listing.price, "Insufficient funds");

        delete listings[_nftContract][_tokenId];

        _distributeFunds(listing.price, listing.seller);

        // Transfer NFT from Escrow to Buyer
        IERC721(_nftContract).safeTransferFrom(address(this), msg.sender, _tokenId);

        // Refund any excess ETH mistakenly sent
        if (msg.value > listing.price) {
            payable(msg.sender).transfer(msg.value - listing.price);
        }

        emit Sold(_nftContract, _tokenId, listing.price, listing.seller, msg.sender);
    }

    /**
     * @notice Cancel your listing and retrieve the NFT from Escrow.
     */
    function cancelListing(address _nftContract, uint256 _tokenId) external nonReentrant {
        Listing memory listing = listings[_nftContract][_tokenId];
        require(listing.price > 0, "Not listed");
        require(listing.seller == msg.sender, "Not seller");

        delete listings[_nftContract][_tokenId];

        // Transfer NFT from Escrow back to Seller
        IERC721(_nftContract).safeTransferFrom(address(this), msg.sender, _tokenId);

        emit ListingCanceled(_nftContract, _tokenId, msg.sender);
    }

    // --- 2. Item Offers (Bidding on Specific NFT) ---

    /**
     * @notice Make an offer on a specific NFT by locking ETH in the contract.
     */
    function makeItemOffer(address _nftContract, uint256 _tokenId) external payable nonReentrant {
        require(msg.value > 0, "Offer must be > 0");

        // Top up existing offer if any
        itemOffers[_nftContract][_tokenId][msg.sender].price += msg.value;

        emit ItemOfferMade(_nftContract, _tokenId, itemOffers[_nftContract][_tokenId][msg.sender].price, msg.sender);
    }

    /**
     * @notice Accept an offer placed on your NFT. 
     * Handles whether the NFT is currently in Escrow or in your wallet.
     */
    function acceptItemOffer(address _nftContract, uint256 _tokenId, address _offerer) external nonReentrant {
        uint256 offerPrice = itemOffers[_nftContract][_tokenId][_offerer].price;
        require(offerPrice > 0, "No offer exists");

        delete itemOffers[_nftContract][_tokenId][_offerer];

        Listing memory listing = listings[_nftContract][_tokenId];
        address seller;

        if (listing.price > 0 && listing.seller == msg.sender) {
            // Unlist from Escrow and send directly to offerer
            delete listings[_nftContract][_tokenId];
            seller = msg.sender;
            IERC721(_nftContract).safeTransferFrom(address(this), _offerer, _tokenId);
        } else {
            // Seller holds it in their wallet. They must have Approved the marketplace.
            require(IERC721(_nftContract).ownerOf(_tokenId) == msg.sender, "Not the owner");
            seller = msg.sender;
            IERC721(_nftContract).safeTransferFrom(msg.sender, _offerer, _tokenId);
        }

        _distributeFunds(offerPrice, payable(seller));

        emit ItemOfferAccepted(_nftContract, _tokenId, offerPrice, _offerer, seller);
    }

    /**
     * @notice Withdraw your ETH offer for a specific item.
     */
    function cancelItemOffer(address _nftContract, uint256 _tokenId) external nonReentrant {
        uint256 offerPrice = itemOffers[_nftContract][_tokenId][msg.sender].price;
        require(offerPrice > 0, "No offer exists");

        delete itemOffers[_nftContract][_tokenId][msg.sender];

        (bool success, ) = payable(msg.sender).call{value: offerPrice}("");
        require(success, "Transfer failed");

        emit ItemOfferCanceled(_nftContract, _tokenId, msg.sender);
    }

    // --- 3. Collection Offers (Bidding on ANY item in a Collection) ---

    /**
     * @notice Lock ETH as an offer for ANY item in the specified Collection.
     */
    function makeCollectionOffer(address _nftContract) external payable nonReentrant {
        require(msg.value > 0, "Offer must be > 0");

        collectionOffers[_nftContract][msg.sender].price += msg.value;

        emit CollectionOfferMade(_nftContract, collectionOffers[_nftContract][msg.sender].price, msg.sender);
    }

    /**
     * @notice Supplying any NFT from the collection to satisfy a buyer's Collection Offer.
     */
    function acceptCollectionOffer(address _nftContract, uint256 _tokenId, address _offerer) external nonReentrant {
        uint256 offerPrice = collectionOffers[_nftContract][_offerer].price;
        require(offerPrice > 0, "No offer exists");

        // Consume the collection offer completely
        delete collectionOffers[_nftContract][_offerer];

        Listing memory listing = listings[_nftContract][_tokenId];
        address seller;

        if (listing.price > 0 && listing.seller == msg.sender) {
            // Fulfill using an escrowed item
            delete listings[_nftContract][_tokenId];
            seller = msg.sender;
            IERC721(_nftContract).safeTransferFrom(address(this), _offerer, _tokenId);
        } else {
            // Fulfill using an item from the seller's wallet
            require(IERC721(_nftContract).ownerOf(_tokenId) == msg.sender, "Not the owner");
            seller = msg.sender;
            IERC721(_nftContract).safeTransferFrom(msg.sender, _offerer, _tokenId);
        }

        _distributeFunds(offerPrice, payable(seller));

        emit CollectionOfferAccepted(_nftContract, _tokenId, offerPrice, _offerer, seller);
    }

    /**
     * @notice Withdraw your ETH collection offer.
     */
    function cancelCollectionOffer(address _nftContract) external nonReentrant {
        uint256 offerPrice = collectionOffers[_nftContract][msg.sender].price;
        require(offerPrice > 0, "No offer exists");

        delete collectionOffers[_nftContract][msg.sender];

        (bool success, ) = payable(msg.sender).call{value: offerPrice}("");
        require(success, "Transfer failed");

        emit CollectionOfferCanceled(_nftContract, msg.sender);
    }

    // --- Internal Helpers ---

    /**
     * @dev Calculates and distributes the fee to the `feeAccount` and the remaining cut to the seller.
     */
    function _distributeFunds(uint256 _price, address payable _seller) internal {
        // e.g. If _price = 100 ether, feePercent = 25 (2.5%) => (100 * 25) / 1000 = 2.5 ether
        uint256 fee = (_price * feePercent) / 1000; 
        uint256 sellerCut = _price - fee;

        if (fee > 0) {
            (bool feeSuccess, ) = feeAccount.call{value: fee}("");
            require(feeSuccess, "Fee transfer failed");
        }

        (bool sellerSuccess, ) = _seller.call{value: sellerCut}("");
        require(sellerSuccess, "Seller transfer failed");
    }
}
