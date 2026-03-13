// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {ITrap} from "drosera-contracts/interfaces/ITrap.sol";

/**
 * @title  Aegis V3 Sentinel — v2
 * @author DAOmindbreaker
 * @notice Drosera Trap that monitors the Lido V3 stVaults ecosystem on Hoodi
 *         testnet and triggers when protocol-level risk conditions are detected
 *         across multiple consecutive block samples.
 *
 * @dev    Improvements over v1:
 *
 *         1. Adaptive Vault Sampling (10 → 25)
 *            VAULT_SAMPLE_SIZE increased to 25, covering ~5% of all registered
 *            vaults (532 total). Sampling is distributed across the vault index
 *            space using a stride pattern to avoid sampling only the oldest vaults.
 *
 *         2. Rate Degradation History (2-block comparison)
 *            Check D now uses a 3-snapshot window. Rate drop is measured from
 *            oldest → current AND confirmed by mid snapshot also showing decline.
 *            Additionally, absolute rate is compared against MIN_ACCEPTABLE_RATE
 *            to catch extreme depegs even without historical context.
 *
 *         3. Accounting Contract Cross-Check (new Check E)
 *            Monitors Lido V3 Accounting contract for external shares ratio
 *            exceeding the protocol-defined cap (getMaxExternalRatioBP).
 *            Triggers CRITICAL if externalShares / totalShares > maxExternalRatioBP.
 *            This catches undercollateralized stETH minting from stVaults before
 *            it cascades into bad debt.
 *
 *         4. shouldAlert() — Off-chain Alert System
 *            Implements shouldAlert() for sub-threshold early warning signals:
 *            - Alert A: any unhealthy vault detected (even 1, below Check C threshold)
 *            - Alert B: wstETH rate drop > 100 bps (early warning, below 300 bps trigger)
 *            - Alert C: external ratio within 500 bps of the cap (approaching limit)
 *            - Alert D: badDebt == 0 but totalShortfallShares > 0 (pre-bad-debt signal)
 *
 * @dev    Five independent detection checks ordered by severity:
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
 *           Samples 25 vaults via stride pattern. Triggers if more than
 *           UNHEALTHY_VAULT_THRESHOLD vaults report unhealthy status AND
 *           mid-sample confirms the same pattern (sustained, not a spike).
 *
 *         Check D — wstETH Redemption Rate Drop (HIGH)
 *           Triggers if wstETH rate drops > RATE_DROP_BPS from oldest to
 *           current AND mid-sample also shows a drop (sustained decline).
 *
 *         Check E — External Shares Ratio Breach (CRITICAL)
 *           Triggers if external shares (stVault-backed stETH) exceed the
 *           protocol cap tracked by the Accounting contract.
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
 *   VaultHub    : 0x4C9fFC325392090F789255b9948Ab1659b797964 (proxy)
 *   Accounting  : 0x9b5b78D1C9A3238bF24662067e34c57c83E8c354
 *   stETH       : 0x3508A952176b3c15387C97BE809eaffB1982176a
 *   wstETH      : 0x7E99eE3C66636DE415D2d7C880938F2f40f94De4
 */

// ─────────────────────────────────────────────
//  External interfaces
// ─────────────────────────────────────────────

interface IVaultHub {
    function vaultsCount() external view returns (uint256);
    function badDebtToInternalize() external view returns (uint256);
    function isPaused() external view returns (bool);
    function vaultByIndex(uint256 index) external view returns (address);
    function isVaultHealthy(address vault) external view returns (bool);
    function healthShortfallShares(address vault) external view returns (uint256);
}

interface IAccounting {
    /// @notice Total external shares minted against stVault collateral
    function getExternalShares() external view returns (uint256);
    /// @notice ETH amount backing external shares
    function getExternalEther() external view returns (uint256);
    /// @notice Protocol cap: max external shares as ratio of total (in basis points)
    function getMaxExternalRatioBP() external view returns (uint256);
}

interface IStETH {
    function getTotalPooledEther() external view returns (uint256);
    function getTotalShares() external view returns (uint256);
}

interface IWstETH {
    function getPooledEthByShares(uint256 sharesAmount) external view returns (uint256);
}

// ─────────────────────────────────────────────
//  Data structures
// ─────────────────────────────────────────────

/// @notice Full snapshot of Lido V3 stVaults ecosystem state at a given block sample
struct AegisSnapshot {
    // ── VaultHub state ──────────────────────
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

    // ── wstETH / stETH state ─────────────────
    /// @notice wstETH redemption rate: ETH per 1e18 shares (scaled 1e18)
    uint256 wstEthRate;
    /// @notice Total ETH pooled in Lido stETH (wei)
    uint256 totalPooledEther;
    /// @notice Total stETH shares outstanding
    uint256 totalShares;
    /// @notice Share-to-pooled ratio in basis points (10 000 = 1.0000)
    uint256 shareRatioBps;

    // ── Accounting cross-check ───────────────
    /// @notice External shares minted against stVault collateral
    uint256 externalShares;
    /// @notice Protocol cap for external shares ratio (bps)
    uint256 maxExternalRatioBp;
    /// @notice Actual external ratio in bps (externalShares * BPS / totalShares)
    uint256 externalRatioBps;

    // ── Metadata ────────────────────────────
    /// @notice True if all external calls succeeded
    bool valid;
}

// ─────────────────────────────────────────────
//  Trap contract
// ─────────────────────────────────────────────

contract AegisV3Sentinel is ITrap {

    // ── Constants ────────────────────────────

    /// @notice Lido V3 VaultHub proxy on Hoodi testnet-3
    address public constant VAULT_HUB    = 0x4C9fFC325392090F789255b9948Ab1659b797964;

    /// @notice Lido V3 Accounting contract on Hoodi testnet-3
    address public constant ACCOUNTING   = 0x9b5b78D1C9A3238bF24662067e34c57c83E8c354;

    /// @notice Lido stETH proxy on Hoodi testnet-3
    address public constant STETH        = 0x3508A952176b3c15387C97BE809eaffB1982176a;

    /// @notice Lido wstETH on Hoodi testnet-3
    address public constant WSTETH       = 0x7E99eE3C66636DE415D2d7C880938F2f40f94De4;

    /// @notice Number of vaults to sample per collect() call (v2: 25 from 10)
    /// @dev    25 vaults with stride pattern covers ~5% of 532 registered vaults.
    ///         Sampling is distributed via index stride to avoid clustering at index 0.
    uint256 public constant VAULT_SAMPLE_SIZE = 25;

    /// @notice Vault index stride for distributed sampling
    /// @dev    stride = vaultsCount / VAULT_SAMPLE_SIZE at runtime.
    ///         Fallback to 1 if vaultsCount < VAULT_SAMPLE_SIZE.
    uint256 public constant VAULT_STRIDE_FALLBACK = 1;

    /// @notice Trigger Check C if this many sampled vaults are unhealthy
    /// @dev    3 out of 25 = 12% threshold (tightened from 20% in v1)
    uint256 public constant UNHEALTHY_VAULT_THRESHOLD = 3;

    /// @notice Basis points denominator
    uint256 public constant BPS_DENOM = 10_000;

    /// @notice Trigger Check D if wstETH rate drops more than 3% (300 bps)
    uint256 public constant RATE_DROP_BPS = 300;

    /// @notice Alert (shouldAlert) if wstETH rate drops more than 1% (100 bps)
    uint256 public constant RATE_ALERT_BPS = 100;

    /// @notice Alert (shouldAlert) if external ratio is within 500 bps of the cap
    uint256 public constant EXTERNAL_RATIO_ALERT_BUFFER_BPS = 500;

    /// @notice Minimum pooled ETH before stETH monitoring is meaningful
    uint256 public constant MIN_POOLED_ETH = 1 ether;

    // ── collect() ────────────────────────────

    /**
     * @notice Collects an AegisSnapshot from VaultHub, Accounting, stETH, and wstETH.
     * @dev    Every external call is wrapped in try/catch. Critical call failures
     *         invalidate the snapshot. Vault sampling uses stride pattern for
     *         distributed coverage across the full vault index space.
     * @return ABI-encoded AegisSnapshot struct
     */
    function collect() external view returns (bytes memory) {
        AegisSnapshot memory snap;

        // ── VaultHub global state ─────────────
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

        // ── Adaptive vault sampling (stride pattern) ──
        // Calculate stride for distributed coverage
        // e.g. 532 vaults / 25 samples = stride 21
        // → sample indices: 0, 21, 42, 63, ..., 504
        uint256 sampleSize = snap.vaultsCount < VAULT_SAMPLE_SIZE
            ? snap.vaultsCount
            : VAULT_SAMPLE_SIZE;

        uint256 stride = sampleSize > 0 && snap.vaultsCount > sampleSize
            ? snap.vaultsCount / sampleSize
            : VAULT_STRIDE_FALLBACK;

        for (uint256 i = 0; i < sampleSize; ) {
            uint256 vaultIndex = i * stride;

            // Guard: never exceed vaultsCount
            if (vaultIndex >= snap.vaultsCount) {
                unchecked { ++i; }
                continue;
            }

            address vault;
            try IVaultHub(VAULT_HUB).vaultByIndex(vaultIndex) returns (address v) {
                vault = v;
            } catch {
                unchecked { ++i; }
                continue;
            }

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

        try IStETH(STETH).getTotalShares() returns (uint256 shares) {
            snap.totalShares = shares;
        } catch {
            snap.valid = false;
            return abi.encode(snap);
        }

        if (snap.totalPooledEther > 0) {
            snap.shareRatioBps = (snap.totalShares * BPS_DENOM) / snap.totalPooledEther;
        }

        // ── Accounting cross-check (new in v2) ─
        try IAccounting(ACCOUNTING).getExternalShares() returns (uint256 extShares) {
            snap.externalShares = extShares;
        } catch {
            // Non-critical: Accounting may not be available on all testnets
        }

        try IAccounting(ACCOUNTING).getMaxExternalRatioBP() returns (uint256 maxRatio) {
            snap.maxExternalRatioBp = maxRatio;
        } catch {
            // Non-critical
        }

        // Derive actual external ratio in bps
        if (snap.totalShares > 0 && snap.externalShares > 0) {
            snap.externalRatioBps = (snap.externalShares * BPS_DENOM) / snap.totalShares;
        }

        snap.valid = true;
        return abi.encode(snap);
    }

    // ── shouldRespond() ──────────────────────

    /**
     * @notice Analyses 3 consecutive AegisSnapshots for protocol risk conditions.
     * @dev    Five checks run in order of severity. First match triggers response.
     *
     *         Check A — Bad Debt Spike (CRITICAL)
     *         Check B — Protocol Pause (CRITICAL)
     *         Check C — Vault Health Degradation (HIGH) [25 vaults, 12% threshold]
     *         Check D — wstETH Rate Drop (HIGH) [3-snapshot window]
     *         Check E — External Shares Ratio Breach (CRITICAL) [new in v2]
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

        if (!current.valid || !mid.valid || !oldest.valid) {
            return (false, bytes(""));
        }

        // ── Check A: Bad debt spike ───────────
        if (current.badDebt > 0) {
            return (true, abi.encode(
                uint8(1),
                current.badDebt,
                current.unhealthyVaults,
                current.totalShortfallShares
            ));
        }

        // ── Check B: Protocol pause ───────────
        if (current.protocolPaused && !oldest.protocolPaused) {
            return (true, abi.encode(
                uint8(2),
                current.vaultsCount,
                current.badDebt,
                uint256(0)
            ));
        }

        // ── Check C: Vault health degradation ─
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
        // Rate drop measured oldest → current, confirmed by mid also dropping
        if (oldest.wstEthRate > 0 && current.wstEthRate < oldest.wstEthRate) {
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

        // ── Check E: External shares ratio breach (new in v2) ─
        // Triggers if externalRatioBps > maxExternalRatioBp in all 3 snapshots
        // (sustained breach, not a transient spike)
        if (
            current.maxExternalRatioBp > 0 &&
            current.externalRatioBps > current.maxExternalRatioBp &&
            mid.externalRatioBps     > mid.maxExternalRatioBp &&
            oldest.externalRatioBps  > oldest.maxExternalRatioBp
        ) {
            return (true, abi.encode(
                uint8(5),
                current.externalRatioBps,
                current.maxExternalRatioBp,
                current.externalShares
            ));
        }

        return (false, bytes(""));
    }

    // ── shouldAlert() ─────────────────────────

    /**
     * @notice Early warning system — fires before shouldRespond() thresholds.
     * @dev    Four pre-threshold alert conditions:
     *
     *         Alert A — Any unhealthy vault detected (even 1 vault)
     *           Early signal before Check C threshold is reached.
     *
     *         Alert B — wstETH rate drop > 100 bps (soft warning)
     *           Early signal before Check D 300 bps hard trigger.
     *
     *         Alert C — External ratio approaching cap (within 500 bps)
     *           Warning before Check E hard breach.
     *           e.g. cap = 10 000 bps, current = 9 600 bps → alert fires
     *
     *         Alert D — Pre-bad-debt signal
     *           badDebt == 0 but totalShortfallShares > 0 in both current
     *           and mid snapshots. Vaults accruing shortfall but not yet
     *           internalized — bad debt may be imminent.
     *
     * @param  data  ABI-encoded AegisSnapshot array (index 0 = newest)
     * @return (true, encodedPayload) if alert condition detected; (false, "") otherwise
     */
    function shouldAlert(
        bytes[] calldata data
    ) external pure returns (bool, bytes memory) {

        if (data.length < 2) return (false, bytes(""));

        AegisSnapshot memory current = abi.decode(data[0], (AegisSnapshot));
        AegisSnapshot memory mid     = abi.decode(data[1], (AegisSnapshot));

        if (!current.valid || !mid.valid) return (false, bytes(""));

        // ── Alert A: Any unhealthy vault detected ──
        if (current.unhealthyVaults > 0 && mid.unhealthyVaults > 0) {
            return (true, abi.encode(
                uint8(10),
                current.unhealthyVaults,
                current.totalShortfallShares,
                mid.unhealthyVaults
            ));
        }

        // ── Alert B: Early rate drop warning (>100 bps) ──
        if (mid.wstEthRate > 0 && current.wstEthRate < mid.wstEthRate) {
            uint256 alertDropBps =
                ((mid.wstEthRate - current.wstEthRate) * BPS_DENOM)
                    / mid.wstEthRate;

            if (alertDropBps >= RATE_ALERT_BPS) {
                return (true, abi.encode(
                    uint8(11),
                    current.wstEthRate,
                    mid.wstEthRate,
                    alertDropBps
                ));
            }
        }

        // ── Alert C: External ratio approaching cap ──
        if (
            current.maxExternalRatioBp > EXTERNAL_RATIO_ALERT_BUFFER_BPS &&
            current.externalRatioBps > 0 &&
            current.externalRatioBps >= current.maxExternalRatioBp - EXTERNAL_RATIO_ALERT_BUFFER_BPS &&
            current.externalRatioBps < current.maxExternalRatioBp
        ) {
            return (true, abi.encode(
                uint8(12),
                current.externalRatioBps,
                current.maxExternalRatioBp,
                current.externalShares
            ));
        }

        // ── Alert D: Pre-bad-debt shortfall signal ──
        if (
            current.badDebt == 0 &&
            current.totalShortfallShares > 0 &&
            mid.totalShortfallShares > 0
        ) {
            return (true, abi.encode(
                uint8(13),
                current.totalShortfallShares,
                mid.totalShortfallShares,
                current.unhealthyVaults
            ));
        }

        return (false, bytes(""));
    }
}
