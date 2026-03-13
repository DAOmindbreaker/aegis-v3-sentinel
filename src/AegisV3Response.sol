// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title  Aegis V3 Response
 * @author DAOmindbreaker
 * @notice On-chain response contract for the AegisV3Sentinel Drosera Trap.
 *         Receives structured risk reports from the Trap and emits fully typed
 *         events so that any off-chain indexer, alert system, or governance
 *         module can react to Lido V3 stVaults risk conditions in real time.
 *
 * @dev    Four response entry-points map 1-to-1 with detection checks:
 *           - recordBadDebt()                → Check A (CRITICAL)
 *           - recordProtocolPause()          → Check B (CRITICAL)
 *           - recordVaultHealthDegradation() → Check C (HIGH)
 *           - recordRedemptionRateDrop()     → Check D (HIGH)
 *
 *         All ETH values are in wei (1e18).
 *         All rates are scaled 1e18.
 *         All deviations are in basis points (10 000 = 100%).
 */

contract AegisV3Response {

    // ─────────────────────────────────────────
    //  State
    // ─────────────────────────────────────────

    /// @notice Address of the authorised AegisV3Sentinel Trap
    address public immutable AUTHORISED_TRAP;

    /// @notice Deployer / admin
    address public immutable ADMIN;

    /// @notice Monotonically increasing counter — unique ID per risk report
    uint256 public riskReportCount;

    /// @notice Count of CRITICAL severity reports
    uint256 public criticalCount;

    /// @notice Count of HIGH severity reports
    uint256 public highCount;

    // ─────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────

    /**
     * @notice Emitted when bad debt is detected in VaultHub (Check A — CRITICAL)
     * @param id               Unique risk report ID
     * @param badDebt          Total bad debt pending internalization (wei)
     * @param unhealthyVaults  Number of unhealthy vaults in sample
     * @param totalShortfall   Total shortfall shares across sampled vaults
     * @param timestamp        Block timestamp of detection
     */
    event BadDebtDetected(
        uint256 indexed id,
        uint256 badDebt,
        uint256 unhealthyVaults,
        uint256 totalShortfall,
        uint256 timestamp
    );

    /**
     * @notice Emitted when VaultHub transitions to paused state (Check B — CRITICAL)
     * @param id           Unique risk report ID
     * @param vaultsCount  Total connected vaults at time of pause
     * @param badDebt      Bad debt at time of pause (wei)
     * @param timestamp    Block timestamp of detection
     */
    event ProtocolPaused(
        uint256 indexed id,
        uint256 vaultsCount,
        uint256 badDebt,
        uint256 timestamp
    );

    /**
     * @notice Emitted when sustained vault health degradation is detected (Check C — HIGH)
     * @param id                      Unique risk report ID
     * @param currentUnhealthyVaults  Unhealthy vault count in current sample
     * @param totalShortfallShares    Total shortfall shares in current sample
     * @param midUnhealthyVaults      Unhealthy vault count in mid sample
     * @param timestamp               Block timestamp of detection
     */
    event VaultHealthDegradation(
        uint256 indexed id,
        uint256 currentUnhealthyVaults,
        uint256 totalShortfallShares,
        uint256 midUnhealthyVaults,
        uint256 timestamp
    );

    /**
     * @notice Emitted when sustained wstETH redemption rate drop is detected (Check D — HIGH)
     * @param id            Unique risk report ID
     * @param currentRate   Current wstETH rate (ETH per 1e18 shares)
     * @param baselineRate  Oldest sample wstETH rate
     * @param dropBps       Drop magnitude in basis points
     * @param timestamp     Block timestamp of detection
     */
    event RedemptionRateDrop(
        uint256 indexed id,
        uint256 currentRate,
        uint256 baselineRate,
        uint256 dropBps,
        uint256 timestamp
    );

    /// @notice Emitted when an unauthorised caller attempts to submit a report
    event UnauthorisedCall(address indexed caller, uint256 timestamp);

    // ─────────────────────────────────────────
    //  Errors
    // ─────────────────────────────────────────

    /// @dev Reverts when caller is not the authorised Trap contract
    error NotAuthorisedTrap(address caller);

    /// @dev Reverts when payload values are invalid
    error InvalidPayload();

    // ─────────────────────────────────────────
    //  Modifier
    // ─────────────────────────────────────────

    modifier onlyTrap() {
        _onlyTrap();
        _;
    }

    function _onlyTrap() internal {
        if (msg.sender != AUTHORISED_TRAP) {
            emit UnauthorisedCall(msg.sender, block.timestamp);
            revert NotAuthorisedTrap(msg.sender);
        }
    }

    // ─────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────

    /**
     * @param _authorisedTrap Address of the AegisV3Sentinel Trap
     */
    constructor(address _authorisedTrap) {
        require(_authorisedTrap != address(0), "AegisV3Response: zero address");
        AUTHORISED_TRAP = _authorisedTrap;
        ADMIN           = msg.sender;
    }

    // ─────────────────────────────────────────
    //  Response functions
    // ─────────────────────────────────────────

    /**
     * @notice Called by Trap when Check A fires — bad debt detected (CRITICAL)
     * @param badDebt          Total bad debt pending internalization (wei)
     * @param unhealthyVaults  Number of unhealthy vaults in sample
     * @param totalShortfall   Total shortfall shares across sampled vaults
     */
    function recordBadDebt(
        uint256 badDebt,
        uint256 unhealthyVaults,
        uint256 totalShortfall
    ) external onlyTrap {
        if (badDebt == 0) revert InvalidPayload();
        uint256 id = ++riskReportCount;
        unchecked { ++criticalCount; }
        emit BadDebtDetected(id, badDebt, unhealthyVaults, totalShortfall, block.timestamp);
    }

    /**
     * @notice Called by Trap when Check B fires — protocol paused (CRITICAL)
     * @param vaultsCount  Total connected vaults at time of pause
     * @param badDebt      Bad debt at time of pause (wei)
     */
    function recordProtocolPause(
        uint256 vaultsCount,
        uint256 badDebt
    ) external onlyTrap {
        if (vaultsCount == 0) revert InvalidPayload();
        uint256 id = ++riskReportCount;
        unchecked { ++criticalCount; }
        emit ProtocolPaused(id, vaultsCount, badDebt, block.timestamp);
    }

    /**
     * @notice Called by Trap when Check C fires — vault health degradation (HIGH)
     * @param currentUnhealthyVaults  Unhealthy vault count in current sample
     * @param totalShortfallShares    Total shortfall shares in current sample
     * @param midUnhealthyVaults      Unhealthy vault count in mid sample
     */
    function recordVaultHealthDegradation(
        uint256 currentUnhealthyVaults,
        uint256 totalShortfallShares,
        uint256 midUnhealthyVaults
    ) external onlyTrap {
        if (currentUnhealthyVaults == 0) revert InvalidPayload();
        uint256 id = ++riskReportCount;
        unchecked { ++highCount; }
        emit VaultHealthDegradation(
            id,
            currentUnhealthyVaults,
            totalShortfallShares,
            midUnhealthyVaults,
            block.timestamp
        );
    }

    /**
     * @notice Called by Trap when Check D fires — redemption rate drop (HIGH)
     * @param currentRate   Current wstETH redemption rate
     * @param baselineRate  Oldest sample wstETH rate
     * @param dropBps       Drop magnitude in basis points
     */
    function recordRedemptionRateDrop(
        uint256 currentRate,
        uint256 baselineRate,
        uint256 dropBps
    ) external onlyTrap {
        if (currentRate == 0 || baselineRate == 0) revert InvalidPayload();
        uint256 id = ++riskReportCount;
        unchecked { ++highCount; }
        emit RedemptionRateDrop(id, currentRate, baselineRate, dropBps, block.timestamp);
    }

    // ─────────────────────────────────────────
    //  View helpers
    // ─────────────────────────────────────────

    /// @notice Returns total number of risk reports recorded
    function totalReports() external view returns (uint256) {
        return riskReportCount;
    }

    /// @notice Returns authorised trap address
    function getAuthorisedTrap() external view returns (address) {
        return AUTHORISED_TRAP;
    }

    /// @notice Returns severity breakdown of all reports
    function severityBreakdown() external view returns (uint256 critical, uint256 high) {
        return (criticalCount, highCount);
    }
}
