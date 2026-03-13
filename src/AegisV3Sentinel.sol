// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {ITrap} from "drosera-contracts/interfaces/ITrap.sol";

/**
 * @title  Aegis V3 Sentinel
 * @author DAOmindbreaker
 * @notice Drosera Trap that monitors the Lido V3 stVaults ecosystem on Hoodi
 *         testnet and triggers when protocol-level risk conditions are detected
 *         across multiple consecutive block samples.
 *
 * @dev    Four independent detection checks ordered by severity:
 *
 *         Check A — Bad Debt Spike (CRITICAL)
 *           Any non-zero bad debt pending internalization is an immediate
 *           protocol-level risk signal. Triggers on first appearance.
 *
 *         Check B — Protocol Pause (CRITICAL)
 *           VaultHub pause status change false→true indicates emergency
 *           governance intervention. Immediate trigger, no confirmation needed.
 *
 *         Check C — Vault Health Degradation (HIGH)
 *           Samples 10 vaults via vaultByIndex(). Triggers if more than
 *           UNHEALTHY_VAULT_THRESHOLD vaults report unhealthy status AND
 *           mid-sample confirms the same pattern (sustained, not a spike).
 *
 *         Check D — wstETH Redemption Rate Drop (HIGH)
 *           Triggers if wstETH rate drops > RATE_DROP_BPS from oldest to
 *           current AND mid-sample also shows a drop (sustained decline).
 *
 * @dev    Mainnet Extension Path:
 *           This Trap is architected for extensibility. On Ethereum mainnet,
 *           additional monitors can be layered onto the same AegisSnapshot
 *           struct without breaking existing checks:
 *             - Aave V3 Pool: reserve utilization + liquidation threshold
 *             - Uniswap V3:   sqrtPriceX96 TWAP divergence + pool drain
 *             - Curve:        stETH/ETH pool imbalance ratio
 *           The modular interface design ensures protocol-agnostic detection.
 *
 * Contracts monitored (Lido V3 official on Hoodi testnet-3):
 *   VaultHub : 0x4C9fFC325392090F789255b9948Ab1659b797964 (proxy)
 *   stETH    : 0x3508A952176b3c15387C97BE809eaffB1982176a
 *   wstETH   : 0x7E99eE3C66636DE415D2d7C880938F2f40f94De4
 */

// ─────────────────────────────────────────────
//  External interfaces
// ─────────────────────────────────────────────

interface IVaultHub {
    /// @notice Total number of connected stVaults
    function vaultsCount() external view returns (uint256);
    /// @notice Total bad debt pending internalization (wei)
    function badDebtToInternalize() external view returns (uint256);
    /// @notice Whether VaultHub is currently paused
    function isPaused() external view returns (bool);
    /// @notice Returns vault address at given index
    function vaultByIndex(uint256 index) external view returns (address);
    /// @notice Whether a vault passes collateralization health check
    function isVaultHealthy(address vault) external view returns (bool);
    /// @notice Total ETH value locked in a vault (wei)
    function totalValue(address vault) external view returns (uint256);
    /// @notice ETH locked as collateral in a vault (wei)
    function locked(address vault) external view returns (uint256);
    /// @notice Health shortfall in shares for a vault (0 = healthy)
    function healthShortfallShares(address vault) external view returns (uint256);
}

interface IStETH {
    /// @notice Total ETH pooled in Lido protocol (wei)
    function getTotalPooledEther() external view returns (uint256);
    /// @notice Total stETH shares outstanding
    function getTotalShares() external view returns (uint256);
}

interface IWstETH {
    /// @notice ETH redeemable per 1e18 wstETH shares (scaled 1e18)
    function getPooledEthByShares(uint256 sharesAmount) external view returns (uint256);
}

// ─────────────────────────────────────────────
//  Data structures
// ─────────────────────────────────────────────

/// @notice Snapshot of Lido V3 stVaults ecosystem state at a given block sample
struct AegisSnapshot {
    /// @notice Total connected stVaults in VaultHub
    uint256 vaultsCount;
    /// @notice Total bad debt pending internalization (wei)
    uint256 badDebt;
    /// @notice Whether VaultHub is currently paused
    bool protocolPaused;
    /// @notice Number of unhealthy vaults found in VAULT_SAMPLE_SIZE sample
    uint256 unhealthyVaults;
    /// @notice Total shortfall shares across sampled vaults
    uint256 totalShortfallShares;
    /// @notice wstETH redemption rate: ETH per 1e18 shares (scaled 1e18)
    uint256 wstEthRate;
    /// @notice Total ETH pooled in Lido stETH (wei)
    uint256 totalPooledEther;
    /// @notice Share-to-pooled ratio in basis points (10 000 = 1.0000)
    uint256 shareRatioBps;
    /// @notice True if all external calls succeeded
    bool valid;
}

// ─────────────────────────────────────────────
//  Trap contract
// ─────────────────────────────────────────────

contract AegisV3Sentinel is ITrap {

    // ── Constants ────────────────────────────

    /// @notice Lido V3 VaultHub proxy on Hoodi testnet-3
    address public constant VAULT_HUB = 0x4C9fFC325392090F789255b9948Ab1659b797964;

    /// @notice Lido stETH proxy on Hoodi testnet-3
    address public constant STETH = 0x3508A952176b3c15387C97BE809eaffB1982176a;

    /// @notice Lido wstETH on Hoodi testnet-3
    address public constant WSTETH = 0x7E99eE3C66636DE415D2d7C880938F2f40f94De4;

    /// @notice Number of vaults to sample per collect() call
    /// @dev    Sampling 10 out of 532 vaults balances coverage vs gas cost.
    ///         Gas scales linearly — 10 samples ≈ 5 external calls each = 50 calls max.
    uint256 public constant VAULT_SAMPLE_SIZE = 10;

    /// @notice Trigger Check C if this many sampled vaults are unhealthy
    /// @dev    2 out of 10 = 20% threshold
    uint256 public constant UNHEALTHY_VAULT_THRESHOLD = 2;

    /// @notice Basis points denominator (10 000 bps = 100%)
    uint256 public constant BPS_DENOM = 10_000;

    /// @notice Alert if wstETH rate drops more than 3% (300 bps)
    uint256 public constant RATE_DROP_BPS = 300;

    /// @notice Minimum pooled ETH required before stETH monitoring is meaningful
    uint256 public constant MIN_POOLED_ETH = 1 ether;

    // ── collect() ────────────────────────────

    /**
     * @notice Collects an AegisSnapshot from VaultHub, stETH, and wstETH.
     * @dev    Every external call is wrapped in try/catch. If any critical call
     *         fails the snapshot is marked invalid and shouldRespond() skips it.
     *         Vault sampling starts from index 0 and iterates up to
     *         min(VAULT_SAMPLE_SIZE, vaultsCount) to avoid out-of-bounds reads.
     * @return ABI-encoded AegisSnapshot struct
     */
    function collect() external view returns (bytes memory) {
        AegisSnapshot memory snap;

        // ── VaultHub global state ────────────
        try IVaultHub(VAULT_HUB).vaultsCount() returns (uint256 count) {
            snap.vaultsCount = count;
        } catch {
            snap.valid = false;
            return abi.encode(snap);
        }

        try IVaultHub(VAULT_HUB).badDebtToInternalize() returns (uint256 debt) {
            snap.badDebt = debt;
        } catch {
            snap.valid = false;
            return abi.encode(snap);
        }

        try IVaultHub(VAULT_HUB).isPaused() returns (bool paused) {
            snap.protocolPaused = paused;
        } catch {
            snap.valid = false;
            return abi.encode(snap);
        }

        // ── Vault health sampling ─────────────
        // Sample min(VAULT_SAMPLE_SIZE, vaultsCount) vaults from index 0
        uint256 sampleSize = snap.vaultsCount < VAULT_SAMPLE_SIZE
            ? snap.vaultsCount
            : VAULT_SAMPLE_SIZE;

        for (uint256 i = 0; i < sampleSize; ) {
            address vault;

            try IVaultHub(VAULT_HUB).vaultByIndex(i) returns (address v) {
                vault = v;
            } catch {
                // Skip this index on revert — do not invalidate entire snapshot
                unchecked { ++i; }
                continue;
            }

            // Skip zero address — should never happen but defensive check
            if (vault == address(0)) {
                unchecked { ++i; }
                continue;
            }

            try IVaultHub(VAULT_HUB).isVaultHealthy(vault) returns (bool healthy) {
                if (!healthy) {
                    unchecked { ++snap.unhealthyVaults; }
                }
            } catch {
                unchecked { ++i; }
                continue;
            }

            try IVaultHub(VAULT_HUB).healthShortfallShares(vault) returns (uint256 shortfall) {
                snap.totalShortfallShares += shortfall;
            } catch {
                // Non-critical — skip without invalidating
            }

            unchecked { ++i; }
        }

        // ── wstETH redemption rate ────────────
        try IWstETH(WSTETH).getPooledEthByShares(1e18) returns (uint256 rate) {
            snap.wstEthRate = rate;
        } catch {
            snap.valid = false;
            return abi.encode(snap);
        }

        // ── stETH pool health ─────────────────
        try IStETH(STETH).getTotalPooledEther() returns (uint256 pooled) {
            snap.totalPooledEther = pooled;
        } catch {
            snap.valid = false;
            return abi.encode(snap);
        }

        uint256 totalShares;
        try IStETH(STETH).getTotalShares() returns (uint256 shares) {
            totalShares = shares;
        } catch {
            snap.valid = false;
            return abi.encode(snap);
        }

        // ── Derive share ratio in bps ────────
        if (snap.totalPooledEther > 0) {
            snap.shareRatioBps = (totalShares * BPS_DENOM) / snap.totalPooledEther;
        }

        snap.valid = true;
        return abi.encode(snap);
    }

    // ── shouldRespond() ──────────────────────

    /**
     * @notice Analyses 3 consecutive AegisSnapshots for protocol risk conditions.
     * @dev    Four checks run in order of severity. First match triggers response.
     *
     *         Check A — Bad Debt Spike (CRITICAL)
     *           Any non-zero bad debt in current snapshot = immediate trigger.
     *           Bad debt in VaultHub means at least one vault is undercollateralized.
     *
     *         Check B — Protocol Pause (CRITICAL)
     *           Protocol was running (oldest = false) but is now paused (current = true).
     *           Detects emergency governance intervention.
     *
     *         Check C — Vault Health Degradation (HIGH)
     *           Both current and mid snapshots show >= UNHEALTHY_VAULT_THRESHOLD
     *           unhealthy vaults. Sustained degradation across 2 samples.
     *
     *         Check D — wstETH Rate Drop (HIGH)
     *           Rate dropped > RATE_DROP_BPS from oldest to current AND
     *           mid-sample also shows a drop. Sustained decline signal.
     *
     * @param  data  ABI-encoded AegisSnapshot array (index 0 = newest)
     * @return (true, encodedPayload) if risk detected; (false, "") otherwise
     */
    function shouldRespond(
        bytes[] calldata data
    ) external pure returns (bool, bytes memory) {

        if (data.length < 3) return (false, bytes(""));

        AegisSnapshot memory current = abi.decode(data[0], (AegisSnapshot));
        AegisSnapshot memory mid     = abi.decode(data[1], (AegisSnapshot));
        AegisSnapshot memory oldest  = abi.decode(data[2], (AegisSnapshot));

        // Skip if any snapshot failed to collect
        if (!current.valid || !mid.valid || !oldest.valid) {
            return (false, bytes(""));
        }

        // ── Check A: Bad debt spike ───────────
        // Any bad debt > 0 is an immediate CRITICAL signal
        if (current.badDebt > 0) {
            return (true, abi.encode(
                uint8(1),
                current.badDebt,
                current.unhealthyVaults,
                current.totalShortfallShares
            ));
        }

        // ── Check B: Protocol pause ───────────
        // Detects false → true transition (emergency governance action)
        if (current.protocolPaused && !oldest.protocolPaused) {
            return (true, abi.encode(
                uint8(2),
                current.vaultsCount,
                current.badDebt,
                uint256(0)
            ));
        }

        // ── Check C: Vault health degradation ─
        // Both mid and current must breach threshold — sustained, not a spike
        bool currentDegraded = current.unhealthyVaults >= UNHEALTHY_VAULT_THRESHOLD;
        bool midDegraded     = mid.unhealthyVaults     >= UNHEALTHY_VAULT_THRESHOLD;

        if (currentDegraded && midDegraded) {
            return (true, abi.encode(
                uint8(3),
                current.unhealthyVaults,
                current.totalShortfallShares,
                mid.unhealthyVaults
            ));
        }

        // ── Check D: wstETH rate drop ─────────
        if (oldest.wstEthRate > 0 &&
            current.wstEthRate < oldest.wstEthRate) {

            uint256 rateDropBps =
                ((oldest.wstEthRate - current.wstEthRate) * BPS_DENOM)
                    / oldest.wstEthRate;

            bool midAlsoDropped = mid.wstEthRate < oldest.wstEthRate;

            if (rateDropBps >= RATE_DROP_BPS && midAlsoDropped) {
                return (true, abi.encode(
                    uint8(4),
                    current.wstEthRate,
                    oldest.wstEthRate,
                    rateDropBps
                ));
            }
        }

        return (false, bytes(""));
    }
}
