// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {IERC4906} from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title  Streetcat Colony — progressive-reveal charity photo collection
/// @author StreetCat
/// @notice N real photographs of one street-cat colony, pixelated by the
///         artist into S stages. Every token starts at stage 1 (most
///         pixelated). As primary sales approach the fundraising goal, the
///         WHOLE collection sharpens together, reaching full resolution
///         (stage S) when the goal is met. Every mint reveals every cat.
///         Cats are assigned RANDOMLY at mint time: the cat chooses you.
///
/// @dev    One deployment represents one colony; point every colony at the
///         same association Safe. Trust model: no owner, no privileged
///         functions, no proxy, no oracles, no backend, no mutable
///         campaign configuration. `totalRaised` only increases, so the
///         reveal is monotonic by construction. Metadata is expected at
///         https://arweave.net/{manifest}/{tokenId}/{stage}.json
///
///         RANDOMNESS — ACCEPTED TRADE-OFF: assignment mixes prevrandao,
///         the previous blockhash, the caller and remaining supply. This
///         is same-transaction pseudo-randomness: a wrapper contract can
///         call mint(), inspect the drawn id and revert until it gets a
///         desired cat, paying only failed gas. The association accepts
///         this openly: every token shares one fixed price and one shared
///         reveal, so a sniper still pays full price, still funds the
///         colony, and cannot harm any other holder — the only thing they
///         forfeit is their own surprise. VRF or commit-reveal would add
///         cost and friction for no material protection at this scale.
///
///         DEPLOY CHECKLIST — things code cannot verify:
///         1. Fork-test one real mint against the REAL Safe address first.
///            The constructor pings the treasury, but a Safe guard that
///            rejects value transfers would still brick every mint.
///         2. GET every /{id}/{stage}.json manifest path (N × S files) and
///            confirm they resolve BEFORE deploying. The manifest cannot
///            be changed afterwards.
///         3. `goal` must come from the colony's real veterinary budget.
contract StreetcatColony is ERC721, ERC2981, IERC4906, ReentrancyGuard {
    using Strings for uint256;

    uint256 private constant BPS_DENOMINATOR = 10_000;
    bytes4 private constant ERC4906_INTERFACE_ID = 0x49064906;

    // ------------------------------------------------------------------
    // Campaign parameters — fixed forever at deployment
    // ------------------------------------------------------------------

    /// @notice N: number of cats / photographs / tokens. IDs are 1..maxSupply.
    uint256 public immutable maxSupply;

    /// @notice S: number of visual stages. 1 = most pixelated, S = full res.
    uint256 public immutable stages;

    /// @notice Minimum ETH required to mint. Overpayment is allowed and
    ///         welcome: every wei counts toward the reveal of the colony.
    uint256 public immutable mintPrice;

    /// @notice Fundraising goal in wei — derived from the colony's real
    ///         veterinary budget. Recommended: maxSupply * mintPrice.
    ///         Thanks to overpayment the goal can be reached without
    ///         selling every token.
    uint256 public immutable goal;

    /// @notice Immutable recipient of mint proceeds and ERC-2981
    ///         royalties. This contract never custodies campaign funds.
    ///         Secondary-market royalties never pass through this contract
    ///         and never affect the reveal.
    address payable public immutable treasury;

    /// @notice Arweave path-manifest TX id for the METADATA folder, laid
    ///         out as /{tokenId}/{stage}.json. Each JSON points at its
    ///         image by absolute URL into a separate, previously uploaded
    ///         image manifest (two-phase upload: images first, then JSONs,
    ///         because a manifest cannot reference itself).
    string public manifest;

    // ------------------------------------------------------------------
    // Campaign state
    // ------------------------------------------------------------------

    /// @notice Cumulative primary-sale proceeds in wei. Only ever increases.
    uint256 public totalRaised;

    /// @dev Lazy Fisher–Yates pool. Position i (0-based) implicitly holds
    ///      id i+1 until overwritten by a swap. O(1) per draw, no loops.
    mapping(uint256 => uint256) private _pool;

    /// @dev Undrawn ids remaining in the pool.
    uint256 private _remaining;

    // ------------------------------------------------------------------
    // Events & errors
    // ------------------------------------------------------------------

    event Minted(
        address indexed payer,
        address indexed recipient,
        uint256 indexed tokenId,
        uint256 paid,
        uint256 totalRaised,
        uint256 stage
    );

    event ForcedEtherSwept(address indexed caller, uint256 amount);

    error EmptyName();
    error EmptySymbol();
    error EmptyManifest();
    error InvalidSupply();
    error InvalidStageCount();
    error InvalidMintPrice();
    error InvalidGoal();
    error InvalidTreasury();
    error InvalidRoyalty();
    error InvalidRecipient();
    error TreasuryRejectsCalls();
    error SoldOut();
    error InsufficientPayment(uint256 required, uint256 supplied);
    error TreasuryTransferFailed();
    error NoForcedEther();
    error DirectTransfersNotAccepted();

    // ------------------------------------------------------------------

    constructor(
        string memory name_,
        string memory symbol_,
        string memory manifest_,
        uint256 maxSupply_,
        uint256 stages_,
        uint256 mintPrice_,
        uint256 goal_,
        address payable treasury_,
        uint96 royaltyBps_
    ) ERC721(name_, symbol_) {
        if (bytes(name_).length == 0) revert EmptyName();
        if (bytes(symbol_).length == 0) revert EmptySymbol();
        if (bytes(manifest_).length == 0) revert EmptyManifest();
        if (maxSupply_ == 0) revert InvalidSupply();
        if (stages_ < 2) revert InvalidStageCount();
        if (mintPrice_ == 0) revert InvalidMintPrice();
        if (goal_ == 0) revert InvalidGoal();
        if (treasury_ == address(0)) revert InvalidTreasury();
        if (royaltyBps_ > BPS_DENOMINATOR) revert InvalidRoyalty();

        // Sanity ping: catches treasuries that cannot receive plain calls
        // (e.g. a contract with no receive/fallback) at deploy time, not
        // at first mint. Does NOT replace the mainnet-fork test in the
        // deploy checklist.
        (bool ok, ) = treasury_.call{value: 0}("");
        if (!ok) revert TreasuryRejectsCalls();

        manifest = manifest_;
        maxSupply = maxSupply_;
        stages = stages_;
        mintPrice = mintPrice_;
        goal = goal_;
        treasury = treasury_;
        _remaining = maxSupply_;

        _setDefaultRoyalty(treasury_, royaltyBps_);
    }

    // ------------------------------------------------------------------
    // Mint
    // ------------------------------------------------------------------

    /// @notice Adopt a random cat from the colony. Pay at least
    ///         `mintPrice`; anything above it is a donation that
    ///         accelerates the reveal for every holder.
    /// @return tokenId The cat that chose you.
    function mint() external payable returns (uint256 tokenId) {
        return _mintTo(msg.sender);
    }

    /// @notice Adopt a random cat as a gift: `recipient` receives the
    ///         token, the caller pays.
    function mintTo(address recipient)
        external
        payable
        returns (uint256 tokenId)
    {
        return _mintTo(recipient);
    }

    function _mintTo(address recipient)
        private
        nonReentrant
        returns (uint256 tokenId)
    {
        if (recipient == address(0)) revert InvalidRecipient();
        if (_remaining == 0) revert SoldOut();
        if (msg.value < mintPrice) {
            revert InsufficientPayment(mintPrice, msg.value);
        }

        uint256 stageBefore = stageFor(totalRaised);
        uint256 newTotalRaised = totalRaised + msg.value;

        // Effects first: all state is final before any external call.
        totalRaised = newTotalRaised;
        tokenId = _draw();

        _safeMint(recipient, tokenId);

        uint256 stageAfter = stageFor(newTotalRaised);
        if (stageAfter != stageBefore) {
            // ERC-4906: tell marketplaces the WHOLE collection changed.
            emit BatchMetadataUpdate(1, maxSupply);
        }

        emit Minted(
            msg.sender,
            recipient,
            tokenId,
            msg.value,
            newTotalRaised,
            stageAfter
        );

        // Forward 100% to the association Safe. Contract holds nothing.
        _forwardToTreasury(msg.value);
    }

    /// @dev Draws a uniformly random undrawn id in O(1) using a lazy
    ///      Fisher–Yates shuffle over the sparse `_pool` mapping. See the
    ///      RANDOMNESS note in the contract NatSpec for the accepted
    ///      manipulation trade-off.
    function _draw() private returns (uint256 tokenId) {
        uint256 n = _remaining;
        uint256 seed = uint256(
            keccak256(
                abi.encodePacked(
                    block.prevrandao,
                    blockhash(block.number - 1),
                    msg.sender,
                    n
                )
            )
        );
        uint256 i = seed % n;

        uint256 val = _pool[i];
        tokenId = val == 0 ? i + 1 : val;

        uint256 lastIdx = n - 1;
        if (i != lastIdx) {
            uint256 lastVal = _pool[lastIdx];
            _pool[i] = lastVal == 0 ? lastIdx + 1 : lastVal;
        }
        delete _pool[lastIdx]; // storage refund
        _remaining = lastIdx;
    }

    // ------------------------------------------------------------------
    // Reveal logic — pure math, no storage writes, no admin
    // ------------------------------------------------------------------

    /// @notice Stage produced by an arbitrary raised amount. Lets the
    ///         front-end preview "what does 0.5 ETH more unlock?" and lets
    ///         fuzzers attack the math without touching state.
    /// @dev    Full-precision mulDiv: correct for any input, including
    ///         values far beyond real ETH supply.
    function stageFor(uint256 raised) public view returns (uint256) {
        if (raised >= goal) return stages;
        return 1 + Math.mulDiv(raised, stages - 1, goal);
    }

    /// @notice Reveal stage currently shared by the entire collection.
    ///         Monotonic: totalRaised never decreases, so this never drops.
    function currentStage() public view returns (uint256) {
        return stageFor(totalRaised);
    }

    /// @notice Campaign progress in basis points (10000 = goal reached).
    function progressBps() external view returns (uint256) {
        if (totalRaised >= goal) return BPS_DENOMINATOR;
        return Math.mulDiv(totalRaised, BPS_DENOMINATOR, goal);
    }

    /// @notice Number of cats adopted so far.
    function totalMinted() public view returns (uint256) {
        return maxSupply - _remaining;
    }

    /// @notice Number of cats still waiting for adoption.
    function remainingSupply() external view returns (uint256) {
        return _remaining;
    }

    /// @notice Current metadata URI for a minted token. Changes on its own
    ///         as the campaign progresses — nobody updates anything.
    function tokenURI(uint256 tokenId)
        public
        view
        override
        returns (string memory)
    {
        _requireOwned(tokenId);
        return string.concat(
            "https://arweave.net/",
            manifest,
            "/",
            tokenId.toString(),
            "/",
            currentStage().toString(),
            ".json"
        );
    }

    // ------------------------------------------------------------------
    // Plumbing
    // ------------------------------------------------------------------

    /// @notice Sends ETH forcibly placed in this contract (selfdestruct,
    ///         block rewards) to the treasury. Forced ETH does NOT count
    ///         toward `totalRaised`: it did not enter through a mint and
    ///         cannot be attributed, so it must never move the reveal.
    ///         Anyone may trigger this; nobody can redirect the funds.
    function sweepForcedEther() external nonReentrant {
        uint256 amount = address(this).balance;
        if (amount == 0) revert NoForcedEther();

        _forwardToTreasury(amount);
        emit ForcedEtherSwept(msg.sender, amount);
    }

    function _forwardToTreasury(uint256 amount) private {
        (bool success, ) = treasury.call{value: amount}("");
        if (!success) revert TreasuryTransferFailed();
    }

    /// @dev Mints are the campaign's only funding mechanism. Reject stray
    ///      ETH so nothing can enter without being counted.
    receive() external payable {
        revert DirectTransfersNotAccepted();
    }

    fallback() external payable {
        revert DirectTransfersNotAccepted();
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC2981, IERC165)
        returns (bool)
    {
        // Hardcoded on purpose: type(IERC4906).interfaceId would XOR in
        // the inherited ERC-721 and ERC-165 selectors and yield the
        // wrong value.
        return
            interfaceId == ERC4906_INTERFACE_ID ||
            super.supportsInterface(interfaceId);
    }
}
