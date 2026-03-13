# 🛡️ AEGIS-V3 Sentinel

[![Drosera Network](https://img.shields.io/badge/Drosera-Network-6C47FF?style=for-the-badge&logo=ethereum&logoColor=white)](https://drosera.io)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.33-363636?style=for-the-badge&logo=solidity&logoColor=white)](https://soliditylang.org)
[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-FF6B35?style=for-the-badge)](https://getfoundry.sh)
[![Network](https://img.shields.io/badge/Network-Hoodi%20Testnet-0052FF?style=for-the-badge)](https://hoodi.etherscan.io)
[![Version](https://img.shields.io/badge/Version-v3.0-brightgreen?style=for-the-badge)](https://github.com/DAOmindbreaker/aegis-v3-sentinel)
[![License](https://img.shields.io/badge/License-MIT-green?style=for-the-badge)](LICENSE)

> **Lido V3 VaultHub Risk Sentinel** — Real-time on-chain monitoring for the Lido V3 stVaults ecosystem, powered by [Drosera Network](https://drosera.io).

---

## 📌 Overview

AEGIS-V3 is a production-grade [Drosera trap](https://docs.drosera.io) that continuously monitors the **Lido V3 VaultHub** smart contract for systemic risk signals. It samples vault health across a distributed index space, cross-checks the Accounting contract for external shares ratio, tracks wstETH redemption rate degradation across a 3-snapshot window, and fires early-warning alerts before critical thresholds are reached — all in a single, gas-optimized trap execution.

### Why AEGIS-V3?

Lido V3 introduces a fundamentally new architecture — **stVaults** — where third-party operators create isolated staking vaults connected to a central VaultHub. This creates new attack surfaces that didn't exist in Lido V1/V2:

- If multiple vaults become undercollateralized simultaneously, bad debt can **cascade into VaultHub** and affect the entire stETH system
- A protocol pause would **freeze billions in staked ETH** with no on-chain early warning
- External shares minting from stVaults can **exceed the protocol cap**, creating unbacked stETH before bad debt is formally registered
- wstETH redemption rate degradation can signal **accounting manipulation or systemic insolvency** before it becomes visible to users

The `LidoProtocolAnomalySentinel` monitors Lido V1/V2 pooled ETH at the macro level. AEGIS-V3 goes deeper — **monitoring the V3 vault layer in real time**, where the next systemic risk is most likely to originate.

---

## ⚡ Live Deployment (Hoodi Testnet)

| Contract | Address | Explorer |
|---|---|---|
| **AegisV3Sentinel** (Trap) | `0x047aEdd2215C6E22E1a8128A9A98735FfF666aff` | [View ↗](https://hoodi.etherscan.io/address/0x047aEdd2215C6E22E1a8128A9A98735FfF666aff) |
| **AegisV3Response** | `0xEFB450504f7391dE6Fc64aA9c9234B50737C353c` | [View ↗](https://hoodi.etherscan.io/address/0xEFB450504f7391dE6Fc64aA9c9234B50737C353c) |
| **VaultHub** (Monitored) | `0x4C9fFC325392090F789255b9948Ab1659b797964` | [View ↗](https://hoodi.etherscan.io/address/0x4C9fFC325392090F789255b9948Ab1659b797964) |
| **Accounting** (Monitored) | `0x9b5b78D1C9A3238bF24662067e34c57c83E8c354` | [View ↗](https://hoodi.etherscan.io/address/0x9b5b78D1C9A3238bF24662067e34c57c83E8c354) |
| **stETH** (Monitored) | `0x3508A952176b3c15387C97BE809eaffB1982176a` | [View ↗](https://hoodi.etherscan.io/address/0x3508A952176b3c15387C97BE809eaffB1982176a) |
| **wstETH** (Monitored) | `0x7E99eE3C66636DE415D2d7C880938F2f40f94De4` | [View ↗](https://hoodi.etherscan.io/address/0x7E99eE3C66636DE415D2d7C880938F2f40f94De4) |

---

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                      Drosera Network                            │
│  ┌─────────────┐    attestation    ┌────────────────────────┐   │
│  │  Operators  │◄─────────────────►│   Drosera Protocol     │   │
│  └──────┬──────┘                   └────────────────────────┘   │
│         │ execute every block                                   │
└─────────┼───────────────────────────────────────────────────────┘
          │
          ▼
┌─────────────────────────────────────────────────────────────────┐
│                  AegisV3Sentinel v3 (Trap)                      │
│                                                                 │
│  collect()               shouldRespond()      shouldAlert()     │
│  ┌─────────────────┐    ┌───────────────┐    ┌──────────────┐  │
│  │ VaultHub:       │    │ Check A (id=1)│    │Alert A(id=10)│  │
│  │ • vaultsCount   │    │ Bad Debt > 0  │    │ Any unhealthy│  │
│  │ • badDebt       │    │ CRITICAL      │    │ vault (≥1)   │  │
│  │ • isPaused      │──► │ Check B (id=2)│    │Alert B(id=11)│  │
│  │ • 25 vaults     │    │ Pause: cur vs │    │ Rate drop    │  │
│  │   (stride)      │    │ mid, CRITICAL │    │ >100 bps     │  │
│  │                 │    │ Check C (id=3)│    │Alert C(id=12)│  │
│  │ Accounting:     │    │ ≥12% unhealthy│    │ ExtRatio     │  │
│  │ • externalShares│    │ proportional  │    │ near cap     │  │
│  │ • maxRatioBP    │    │ HIGH          │    │Alert D(id=13)│  │
│  │ [CRITICAL]      │    │ Check D (id=4)│    │ Pre-bad-debt │  │
│  │                 │    │ Rate drop     │    │ shortfall    │  │
│  │ stETH + wstETH: │    │ >300 bps      │    └──────┬───────┘  │
│  │ • pooledEther   │    │ HIGH          │           │          │
│  │ • totalShares   │    │ Check E (id=5)│           │          │
│  │ • wstEthRate    │    │ ExtRatio      │           │          │
│  └─────────────────┘    │ breach        │           │          │
│                         │ CRITICAL      │           │          │
│                         └──────┬────────┘           │          │
└────────────────────────────────┼────────────────────┼──────────┘
                                 │ should_respond=true │ should_alert=true
                                 ▼                     ▼
┌─────────────────────────────────────────────────────────────────┐
│               AegisV3Response v3 (Response Contract)            │
│                                                                 │
│         handleRisk(uint8 checkId, uint256 a, uint256 b, uint256 c)  │
│                                                                 │
│  id=1  → emit BadDebtDetected(block, badDebt, unhealthy, shortfall) │
│  id=2  → emit ProtocolPauseDetected(block, vaultsCount, badDebt)    │
│  id=3  → emit VaultHealthDegradation(block, unhealthy, shortfall, mid) │
│  id=4  → emit RedemptionRateDrop(block, currentRate, oldestRate, bps)  │
│  id=5  → emit ExternalRatioBreach(block, ratioBps, maxRatio, shares)   │
│  id=10-13 → emit UnknownRiskSignal (alert forward-compat)              │
└─────────────────────────────────────────────────────────────────┘
```

---

## 🔍 How It Works

### Data Collection (`collect()`)

Every block, the sentinel reads a full ecosystem snapshot across 4 contracts:

```solidity
struct AegisSnapshot {
    // VaultHub state
    uint256 vaultsCount;           // Total connected stVaults
    uint256 badDebt;               // Bad debt pending internalization (wei)
    bool    protocolPaused;        // VaultHub pause state
    uint256 unhealthyVaults;       // Unhealthy vaults in 25-vault sample
    uint256 totalShortfallShares;  // Aggregate shortfall across sample
    uint256 sampleSize;            // Actual sample used this block

    // wstETH / stETH state
    uint256 wstEthRate;            // ETH per 1e18 wstETH shares
    uint256 totalPooledEther;      // Total ETH pooled in stETH
    uint256 totalShares;           // Total stETH shares outstanding

    // Accounting cross-check (CRITICAL)
    uint256 externalShares;        // Shares minted against stVault collateral
    uint256 maxExternalRatioBp;    // Protocol cap for external shares (bps)
    uint256 externalRatioBps;      // Actual external ratio (bps)

    bool    valid;                 // Snapshot validity flag
}
```

> **Note:** Accounting contract data is treated as **critical** — if any Accounting call fails, the snapshot is invalidated and no detection runs. This ensures Check E never fires on incomplete data.

### Adaptive Vault Sampling

v3 samples **25 vaults** using a **stride pattern** for distributed coverage:

```
vaultsCount = 532, sampleSize = 25
stride = 532 / 25 = 21

Sampled indices: 0, 21, 42, 63, 84, ..., 504
Coverage: ~5% of all registered vaults, evenly distributed
```

This avoids clustering at index 0 (oldest vaults) and gives a representative cross-section of the entire stVaults ecosystem.

### Risk Detection (`shouldRespond()`)

Five independent checks across a **3-snapshot window**, all encoding to a single `handleRisk` entrypoint:

| Check | ID | Signal | Threshold | Severity |
|---|---|---|---|---|
| **A — Bad Debt** | `1` | `badDebtToInternalize() > 0` | Any bad debt | 🔴 CRITICAL |
| **B — Protocol Pause** | `2` | `isPaused()` current vs mid | Transition detected | 🔴 CRITICAL |
| **C — Vault Health** | `3` | Unhealthy ratio in sample | ≥ 12% proportional, sustained | 🟠 HIGH |
| **D — Rate Drop** | `4` | wstETH/stETH rate decline | > 300 bps, 3-block confirmed | 🟠 HIGH |
| **E — External Ratio** | `5` | externalShares / totalShares > cap | Sustained breach × 3 blocks | 🔴 CRITICAL |

### Response Wiring

All checks encode to one unified payload:

```
shouldRespond() → abi.encode(uint8 checkId, uint256 a, uint256 b, uint256 c)
                          ↓
TOML: response_function = "handleRisk(uint8,uint256,uint256,uint256)"
                          ↓
AegisV3Response.handleRisk() → routes by checkId → emits specific event
```

### Early Warning System (`shouldAlert()`)

Four pre-threshold alerts fire **before** hard triggers, using IDs 10–13:

| Alert | ID | Signal | Threshold | Purpose |
|---|---|---|---|---|
| **A** | `10` | Any unhealthy vault | ≥ 1, sustained | Early degradation signal |
| **B** | `11` | wstETH rate drop | > 100 bps | Soft warning before 300 bps |
| **C** | `12` | External ratio near cap | Within 500 bps | Approaching limit |
| **D** | `13` | Pre-bad-debt shortfall | shortfallShares > 0, badDebt = 0 | Bad debt imminent |

---

## 📊 Performance Stats

### Version Comparison

| Metric | v1 | v2 | v3 |
|---|---|---|---|
| Vault sample size | 10 | 25 | 25 |
| Sampling pattern | Sequential | Stride | Stride |
| Contracts monitored | 3 | 4 | 4 |
| Detection checks | 4 | 5 | 5 |
| Alert signals | 0 | 4 | 4 |
| Response entrypoints | 4 | 4 | **1 (unified)** |
| Authorization model | msg.sender trap | msg.sender trap | **Protocol-native** |
| Check C threshold | Absolute (2/10) | Absolute (3/25) | **Proportional (12%)** |
| Check B detection speed | oldest→current | oldest→current | **mid→current (faster)** |
| Accounting critical | ❌ | ❌ | **✅** |
| `collect()` gas | 385,516 | 915,480 | 915,527 |
| `shouldRespond()` gas | 58,800 | 71,570 | 71,870 |
| Slots queried | 65 | 155 | 155 |

### Live Dryrun (block `2410198`)

| Metric | Value |
|---|---|
| `collect()` gas used | 915,527 |
| `shouldRespond()` gas used | 71,870 |
| `shouldAlert()` gas used | 0 *(protocol healthy)* |
| Accounts queried | 8 |
| Storage slots queried | 155 |
| Bootstrap duration | ~29s |
| Runtime duration | ~589ms |

---

## 🚀 Getting Started

### Prerequisites

- [Foundry](https://getfoundry.sh) installed
- [Drosera CLI](https://docs.drosera.io) installed
- Hoodi testnet ETH (faucet: [hoodi.ethpandaops.io](https://hoodi.ethpandaops.io))

### Installation

```bash
git clone https://github.com/DAOmindbreaker/aegis-v3-sentinel.git
cd aegis-v3-sentinel
forge install
forge build
```

### Run Dryrun

```bash
drosera dryrun
```

Expected output:
```
should_respond: false     ← normal when protocol is healthy
should_alert:   false     ← normal when no pre-threshold conditions
collect() gas used: 915,527
shouldRespond() gas used: 71,870
slots queried: 155 | accounts: 8
```

### Deploy Response Contract

```bash
export PRIVATE_KEY=0xYOUR_PRIVATE_KEY

forge create src/AegisV3Response.sol:AegisV3Response \
  --rpc-url https://ethereum-hoodi-rpc.publicnode.com \
  --private-key $PRIVATE_KEY \
  --broadcast
```

> No constructor args required — authorization is handled by Drosera protocol.

### Configure & Apply Trap

Update `drosera.toml`:

```toml
response_contract = "YOUR_DEPLOYED_RESPONSE_ADDRESS"
response_function = "handleRisk(uint8,uint256,uint256,uint256)"
```

Then apply:

```bash
export DROSERA_PRIVATE_KEY=$PRIVATE_KEY
drosera apply
```

---

## 📁 Project Structure

```
aegis-v3-sentinel/
├── src/
│   ├── AegisV3Sentinel.sol     # Main trap — collection, detection & alerting
│   └── AegisV3Response.sol     # Response contract — single handleRisk entrypoint
├── test/
│   └── (tests coming soon)
├── drosera.toml                # Trap configuration
├── foundry.toml                # Foundry configuration
└── README.md
```

---

## 📋 Changelog

### v3.0
- **Unified response entrypoint**: all 5 checks encode to `handleRisk(uint8,uint256,uint256,uint256)` — TOML wiring fixed
- **Authorization model**: removed `msg.sender` check — Drosera protocol submits callback natively
- **Check E handler**: `id=5` routes to `ExternalRatioBreach` event in response contract
- **Accounting critical**: snapshot invalidated if Accounting calls fail
- **Check C proportional**: `unhealthyVaults/sampleSize >= 12%` instead of absolute count
- **Check B faster**: compares `current` vs `mid` for immediate pause detection
- **Cleanup**: removed unused `getExternalEther()`, `MIN_POOLED_ETH`, `shareRatioBps`

### v2.0
- Adaptive vault sampling: 10 → 25 vaults with stride pattern
- Accounting contract cross-check (Check E)
- Rate degradation 3-snapshot history
- `shouldAlert()` with 4 early warning signals

### v1.0
- Initial release: 4 detection checks
- 10-vault sequential sampling
- VaultHub + stETH + wstETH monitoring

---

## 🤝 Contributing

1. **Fork** this repository
2. **Create** a feature branch: `git checkout -b feat/your-feature`
3. **Build** and verify: `forge build` (must be zero errors)
4. **Dryrun**: `drosera dryrun`
5. **Commit**: `git commit -m "feat: describe your change"`
6. **Open a Pull Request**

### Ideas for Contributions

- [ ] Mainnet deployment configuration
- [ ] Comprehensive Foundry tests
- [ ] Dynamic stride adjustment based on vault count changes
- [ ] Aave V3 cross-protocol risk correlation
- [ ] Uniswap V3 wstETH/ETH pool monitoring
- [ ] Curve stETH/ETH pool imbalance detection

---

## 📜 License

MIT License — see [LICENSE](LICENSE) for details.

---

## 🔗 Resources

- [Drosera Network Docs](https://docs.drosera.io)
- [Lido V3 Documentation](https://docs.lido.fi)
- [VaultHub on Hoodi](https://hoodi.etherscan.io/address/0x4C9fFC325392090F789255b9948Ab1659b797964)
- [Accounting on Hoodi](https://hoodi.etherscan.io/address/0x9b5b78D1C9A3238bF24662067e34c57c83E8c354)
- [Foundry Book](https://book.getfoundry.sh)

---

<p align="center">Built with ❤️ for the Drosera Network ecosystem</p>
