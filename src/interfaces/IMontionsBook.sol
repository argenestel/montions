// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IMontionsBook
/// @notice Fully collateralised binary-outcome market with a fully onchain central limit order book.
/// @dev See docs/SPEC.md for the complete semantics. Units:
///      - USDC has 6 decimals. One contract pays UNIT = 1_000_000 (1 USDC) if its outcome is true.
///      - Prices are integer TICKS 1..99; one tick = TICK_UNIT = 10_000 (0.01 USDC). YES price + NO price = 100 ticks.
///      - `qty` is a whole number of contracts.
interface IMontionsBook {
    // ───────────────────────── types ─────────────────────────
    enum Status { None, Open, Resolved, Void }
    enum Side { Bid, Ask }               // Bid = buy YES, Ask = sell YES (write, or sell held YES)
    enum TIF { GTC, IOC, POST_ONLY }

    struct SeriesInfo {
        address resolver;
        bytes data;
        uint64 expiry;
        Status status;
        bool yes;            // valid when status == Resolved
        uint256 yesId;       // ERC1155 id of the YES token
        uint256 noId;        // ERC1155 id of the NO token
        uint64 createdAt;
    }

    struct PlaceParams {
        bytes32 seriesId;
        Side side;
        uint8 tick;          // 1..99 limit price of YES
        uint64 qty;          // contracts
        bool fromHeld;       // Ask only: sell YES tokens already held instead of writing with collateral
        TIF tif;
        uint16 maxFills;     // matching-loop bound; 0 => default (32)
    }

    struct OrderView {
        uint64 id;
        address maker;
        bytes32 seriesId;
        Side side;
        uint8 tick;
        bool fromHeld;
        uint64 qty;          // remaining
        uint64 origQty;
        uint64 placedAt;
        bool open;
    }

    struct Level { uint8 tick; uint64 qty; }
    struct TradeView { uint64 ts; uint8 tick; uint64 qty; bool takerIsBuyer; }

    // ───────────────────────── events ─────────────────────────
    event SeriesCreated(bytes32 indexed seriesId, address indexed resolver, uint64 expiry, uint256 yesId, uint256 noId);
    event OrderPlaced(uint64 indexed orderId, bytes32 indexed seriesId, address indexed maker, Side side, uint8 tick, uint64 qty, bool fromHeld);
    event OrderCancelled(uint64 indexed orderId, bytes32 indexed seriesId, uint64 qtyCancelled);
    event Trade(bytes32 indexed seriesId, uint64 indexed makerOrderId, address maker, address taker, uint8 tick, uint64 qty, bool takerIsBuyer);
    event Split(bytes32 indexed seriesId, address indexed user, uint64 qty);
    event Merge(bytes32 indexed seriesId, address indexed user, uint64 qty);
    event SeriesResolved(bytes32 indexed seriesId, bool yes);
    event SeriesVoided(bytes32 indexed seriesId);
    event Redeemed(bytes32 indexed seriesId, address indexed user, uint256 yesQty, uint256 noQty, uint256 payout);
    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);

    // ───────────────────────── errors ─────────────────────────
    error BadTick();
    error BadQty();
    error SeriesNotOpen();
    error SeriesExists();
    error SeriesUnknown();
    error ResolverNotAllowed();
    error BadExpiry();
    error NotExpired();
    error AlreadySettled();
    error NotOrderOwner();
    error OrderNotOpen();
    error InsufficientCash();
    error InsufficientTokens();
    error WouldCross();              // POST_ONLY order would match immediately
    error Expired();                 // trading after expiry
    error FeeTooHigh();

    // ───────────────────────── constants ─────────────────────────
    function UNIT() external view returns (uint256);         // 1_000_000
    function TICK_UNIT() external view returns (uint256);    // 10_000
    function TICKS() external view returns (uint256);        // 100
    function MIN_DURATION() external view returns (uint64);  // 120 seconds
    function MAX_DURATION() external view returns (uint64);  // 90 days
    function VOID_GRACE() external view returns (uint64);    // 2 days
    function collateral() external view returns (address);   // USDC

    // ───────────────────────── admin (owner can never touch user funds) ─────────────────────────
    function owner() external view returns (address);
    function setResolverAllowed(address resolver, bool allowed) external;
    function resolverAllowed(address resolver) external view returns (bool);
    function setFee(uint16 takerFeeBps, address recipient) external;   // <= 100 bps, charged on taker premium only
    function takerFeeBps() external view returns (uint16);
    function protocolFees() external view returns (uint256);
    function withdrawFees() external;

    // ───────────────────────── cash account ─────────────────────────
    function deposit(uint256 amount) external;
    function depositWithPermit(uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external;
    function withdraw(uint256 amount) external;
    function cash(address user) external view returns (uint256 free);
    function lockedCash(address user) external view returns (uint256 locked);

    // ───────────────────────── series ─────────────────────────
    function createSeries(address resolver, bytes calldata data, uint64 expiry) external returns (bytes32 seriesId);
    function seriesIdOf(address resolver, bytes calldata data, uint64 expiry) external pure returns (bytes32);
    function seriesInfo(bytes32 seriesId) external view returns (SeriesInfo memory);
    function seriesCount() external view returns (uint256);
    function seriesIdAt(uint256 index) external view returns (bytes32);
    function seriesIds(uint256 offset, uint256 limit) external view returns (bytes32[] memory);

    // ───────────────────────── trading ─────────────────────────
    function placeOrder(PlaceParams calldata p) external returns (uint64 orderId, uint64 filled, uint64 resting);
    function cancelOrder(uint64 orderId) external;
    function cancelOrders(uint64[] calldata orderIds) external;
    function split(bytes32 seriesId, uint64 qty) external;   // pay qty*UNIT, receive qty YES + qty NO
    function merge(bytes32 seriesId, uint64 qty) external;   // burn qty YES + qty NO, receive qty*UNIT (any time before resolution)

    // ───────────────────────── resolution ─────────────────────────
    function resolve(bytes32 seriesId) external;             // anyone, after expiry
    function redeem(bytes32 seriesId, uint256 yesQty, uint256 noQty) external returns (uint256 payout);
    function pool(bytes32 seriesId) external view returns (uint256 collateralHeld);

    // ───────────────────────── views for UIs (no logs needed) ─────────────────────────
    function bestBidAsk(bytes32 seriesId) external view returns (uint8 bidTick, uint64 bidQty, uint8 askTick, uint64 askQty);
    /// @notice aggregated depth, best price first. Bid: descending ticks; Ask: ascending ticks.
    function depth(bytes32 seriesId, Side side, uint8 maxLevels) external view returns (Level[] memory);
    function orderInfo(uint64 orderId) external view returns (OrderView memory);
    function orderCount() external view returns (uint64);
    function userOrderCount(address user) external view returns (uint256);
    function ordersOf(address user, uint256 offset, uint256 limit) external view returns (OrderView[] memory); // newest first
    function recentTrades(bytes32 seriesId, uint8 n) external view returns (TradeView[] memory);              // newest first, ring buffer of 64
    function lastTradeTick(bytes32 seriesId) external view returns (uint8 tick);                              // 0 if none
    function volumeOf(bytes32 seriesId) external view returns (uint256 contractsTraded);

    // ───────────────────────── outcome tokens (ERC1155, hook-free on fills) ─────────────────────────
    function balanceOf(address account, uint256 id) external view returns (uint256);
    function totalSupply(uint256 id) external view returns (uint256);
    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata data) external;
    function setApprovalForAll(address operator, bool approved) external;
    function isApprovedForAll(address account, address operator) external view returns (bool);

    // ───────────────────────── batching ─────────────────────────
    /// @notice delegatecall-batch of this contract's own functions, preserving msg.sender (Solady Multicallable).
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory);
}
