# CAN 2.0 Controller — RTL Architecture & Implementation Guide (Verilog-2001)

**Process Technology**: SCL CP8D 0.8µm CMOS (2 Metal Layers) · **Target Die**: 5 mm × 5 mm (`frame5mmx5mm.gds`)  
**Core Area**: 4,000 µm × 4,000 µm (Origin at 500 µm, 500 µm)  
**Language Standard**: **Synthesizable Verilog-2001 (IEEE 1364-2001)** — *All RTL files use `.v` extension*  
**Submission Portal**: SCL MPW Shuttle via [echiphub.in](https://echiphub.in)  

> [!IMPORTANT]
> **Toolchain Requirement — Pure Verilog (`.v`) Only**:
> Due to parser limitations in Yosys 0.9 (which throws `unexpected TOK_TYPEDEF` on `typedef enum`, `struct`, or `package`), **only standard synthesizable Verilog-2001 (`.v`) is permitted**. All team members must author code using standard `wire`, `reg`, `always @(posedge clk or negedge rst_n)`, and `localparam` state encodings.

---

## 1. What This Chip Does (In Simple Terms)

A **CAN controller** is the dedicated hardware engine that allows microcontrollers, sensors, and actuators to reliably exchange messages across a rugged two-wire differential bus (`CAN_H` and `CAN_L`). CAN is the standard automotive and industrial communications backbone (powertrain, ABS, body electronics, factory automation, robotics).

This chip implements the complete **Bosch CAN 2.0 Specification**:
- **CAN 2.0A**: Standard frames with 11-bit identifiers.
- **CAN 2.0B**: Extended frames with 29-bit identifiers.
- **Hardware Acceptance Filter**: Real-time ID matching using Acceptance Code (ACR) and Acceptance Mask (AMR) registers so the host MCU is only interrupted for relevant traffic.
- **Fault Confinement**: Automatic tracking of Transmit and Receive Error Counters (TEC/REC) transitioning the node safely between Error-Active, Error-Passive, and Bus-Off states.
- **Wafer Characterization Tap**: An integrated ring oscillator tap for measuring wafer-level transistor speed corners (FF, TT, SS) in the lab.

---

## 2. CAN Protocol Fundamentals

### Dominant vs. Recessive Bits
The physical bus operates on "wired-AND" logic:
- **Dominant (`0`)**: Driven actively by the transceiver. A dominant bit always overrides a recessive bit on the bus.
- **Recessive (`1`)**: Passive bus state (high impedance, pulled together by termination resistors).

### Non-Destructive Bitwise Arbitration
When multiple nodes begin transmitting at the same instant (SOF), each node reads back the bus while transmitting its identifier:
- If a node transmits a recessive bit (`1`) but samples a dominant bit (`0`), it knows a higher-priority message (lower ID numerical value) is on the bus.
- The node immediately and gracefully transitions into **Receiver Mode** without corrupting the winning frame, and automatically retransmits once the bus becomes idle.

---

## 3. Frame Formats

### CAN 2.0A — Standard 11-bit ID Frame
```
| SOF (1b) | Base ID [10:0] (11b) | RTR (1b) | IDE=0 (1b) | r0 (1b) | DLC [3:0] (4b) | DATA (0-8 bytes) | CRC [14:0] (15b) | CRC Del (1b) | ACK (1b) | ACK Del (1b) | EOF (7b) | IFS (3b) |
```

### CAN 2.0B — Extended 29-bit ID Frame
```
| SOF (1b) | Base ID [28:18] (11b) | SRR=1 (1b) | IDE=1 (1b) | Ext ID [17:0] (18b) | RTR (1b) | r1 (1b) | r0 (1b) | DLC [3:0] (4b) | DATA (0-8 bytes) | CRC [14:0] (15b) | CRC Del (1b) | ACK (1b) | ACK Del (1b) | EOF (7b) | IFS (3b) |
```

---

## 4. Architectural Module Breakdown

All file names match the verified implementation in `can_controller/1_RTL/`:

```
can_top.v                    ← Chip top-level integration + acceptance filter
├── can_btl.v                ← Bit Timing Logic (prescaler, TQ generation, sample point, sync)
├── can_crc15.v              ← Bosch CRC-15 LFSR calculation engine (poly: 0x4599)
├── can_bit_stuff.v          ← 5-bit rule bit stuffing (TX) + destuffing & stuff error (RX)
├── can_error.v              ← Fault confinement (TEC, REC, Active/Passive/Bus-Off logic)
├── can_fsm.v                ← Protocol state machine (arbitration, bit sequences, error handling)
├── can_reg_bank.v           ← Host register interface (configuration, buffer access, status)
└── ring_oscillator.v        ← Wafer characterization test structure (speed corner monitor)
```

---

## 5. Detailed Module Responsibilities

### 1. `can_btl.v` — Bit Timing Logic (BTL)
Divides the master clock (`clk`) into discrete **Time Quanta (TQ)**:
- $\text{TQ} = (\text{BRP} + 1) \times t_{\text{clk}}$
- Each CAN bit period is composed of:
  1. **Sync_Seg** (Fixed 1 TQ): An edge is expected here.
  2. **Prop_Seg** (1 to 8 TQ): Absorbs signal transit delay through the transceiver and cable.
  3. **Phase_Seg1** (1 to 8 TQ): Lengthened by up to SJW during resynchronization.
  4. **Phase_Seg2** (1 to 8 TQ): Shortened by up to SJW during resynchronization.
- **Combined Segment**: `Prop_Seg + Phase_Seg1` spans **`2..16 TQ`** (4-bit field, encoded as value $- 1$).
- **Sample Point**: Generated at the boundary between `Phase_Seg1` and `Phase_Seg2`.
- **Clock & Speed Guidelines**:
  - At **10 MHz** ($t_{\text{clk}} = 100\text{ ns}$), **500 kbit/s** ($20\text{ TQ/bit}$) provides optimal timing margin with real transceivers (TJA1050/SN65HVD230 with ~200 ns loop delay). At $20\text{ TQ/bit}$: `Sync_Seg = 1 TQ`, `Phase_Seg2 = 4 TQ`, `Prop_Seg + Phase_Seg1 = 15 TQ` (value `4'd14`), `SJW = 2 TQ`.
  - For **1 Mbit/s**, target a **16 MHz** or **20 MHz** clock input to preserve adequate propagation margin.

### 2. `can_crc15.v` — CRC-15 Engine
- Generator polynomial: $x^{15} + x^{14} + x^{10} + x^8 + x^7 + x^4 + x^3 + 1$ (Hex `0x4599`).
- Computes continuously over destuffed bits from SOF through the end of the Data field.
- During transmission, injects the 15-bit calculated checksum into the CRC field.
- During reception, compares incoming CRC bits against the locally computed value; flags a CRC error if any bit differs.

### 3. `can_bit_stuff.v` — Bit Stuffing & Destuffing
- **Transmission**: If 5 consecutive bits of identical polarity occur between SOF and the end of CRC, automatically inserts an inverted "stuff bit".
- **Reception**: Discards the 6th bit if it is an expected stuff bit. If 6 consecutive identical bits are observed, triggers a **Stuff Error**.
- CRC delimiter, ACK slot, ACK delimiter, EOF, and Intermission are framed by fixed formats and are **not stuffed**.

### 4. `can_error.v` — Fault Confinement
- **Transmit Error Counter (TEC)**: Increments by 8 on TX error; decrements by 1 on successful transmission.
- **Receive Error Counter (REC)**: Increments by 1 or 8 on RX error; decrements by 1 on successful reception.
- **Operating States**:
  - **Error Active** ($\text{TEC} < 128$ and $\text{REC} < 128$): Normal node operation. Transmits active (dominant) error flags.
  - **Error Passive** ($\text{TEC} \ge 128$ or $\text{REC} \ge 128$): Suspected faulty. Transmits passive (recessive) error flags; must wait 8 additional suspend bits after Intermission before transmitting again.
  - **Bus-Off** ($\text{TEC} \ge 256$): Disconnected from bus. Recovers only after receiving $128 \times 11$ consecutive recessive bits or via host command (`bus_off_recover`).

### 5. `can_fsm.v` — Protocol State Machine & Edge Cases
Implements the core protocol sequencing:
```
S_IDLE → S_SOF → S_BASE_ID (11b) → S_SRR_RTR → S_IDE 
       ↳ If IDE=1: S_EXT_ID (18b) → S_EXT_RTR → S_R1 → S_R0
       ↳ If IDE=0: S_R0
       ↳ S_DLC (4b) → S_DATA (0-64b) → S_CRC (15b) → S_CRC_DELIM → S_ACK_SLOT → S_ACK_DELIM → S_EOF (7b) → S_INTERMISSION (3b)
       ↳ If Error: S_ERROR_FLAG (6b) → S_ERROR_DELIM (8b)
       ↳ If Overload: S_OVERLOAD_FLAG (6b) → S_OVERLOAD_DELIM (8b)
       ↳ If Error Passive TX: S_SUSPEND (8b recessive)
```

#### Mandatory Protocol Edge Cases
1. **Remote Frame (`RTR == 1`) & Zero-Length Data (`DLC == 0`)**:
   - When `RTR == 1` (Remote Frame) or `DLC == 0`, `S_DLC` must transition **directly to `S_CRC`**, skipping `S_DATA` even if `DLC` is configured to `1..8`.
2. **Overload Frames & 3rd Bit of Intermission**:
   - If a dominant bit is sampled on the **1st or 2nd bit of `S_INTERMISSION`**, transition to `S_OVERLOAD_FLAG` (6 dominant bits) $\rightarrow$ `S_OVERLOAD_DELIM` (8 recessive bits) instead of `S_ERROR_FLAG`. Neither `TEC` nor `REC` are incremented.
   - If a dominant bit is sampled on the **3rd bit of `S_INTERMISSION`**, treat that bit as `SOF` (jump directly to `S_BASE_ID` on the next bit) per Bosch CAN 2.0 Part B Sections 3.2.4–3.2.5.
3. **Receiver EOF Last-Bit Rule**:
   - Receivers validate a frame on the **6th bit (second-to-last bit) of `S_EOF`**. A dominant bit on the 7th (final) bit of `S_EOF` must be ignored and must not trigger a Form Error.
4. **Error Passive Flag Polarity**:
   - In `S_ERROR_FLAG`, `tx_bit` must drive `0` (dominant) when `is_error_active` is true, and `1` (recessive) when `is_error_passive` is true.
   - When an Error Passive node completes transmission, it must enter `S_SUSPEND` (8 recessive bits after Intermission) before initiating any subsequent transmission.

---

### 6. `can_reg_bank.v` — 32-Register Map (`Addr[4:0]`)

Every bit field fits cleanly with zero truncation or bit packing overflow:

| Address | Register Name | Access | Bit Layout & Description |
| :---: | :--- | :---: | :--- |
| `0x00` | `COMMAND` | W | `[0]` `tx_req`, `[1]` `rx_release`, `[2]` `loopback_en`, `[3]` `bus_off_recover` |
| `0x01` | `STATUS` | R | `[0]` `busy`, `[1]` `rx_valid`, `[2]` `tx_done`, `[3]` `err_passive`, `[4]` `bus_off`, `[5]` `rx_ovf` |
| `0x02` | `BTL_BRP_SJW` | R/W | `[7:6]` `SJW - 1` (`1..4 TQ`), `[5:0]` `BRP` (`0..63`, prescaler $1\dots 64$) |
| `0x03` | `BTL_SEG` | R/W | `[6:4]` `Phase_Seg2 - 1` (`1..8 TQ`), `[3:0]` `(Prop_Seg + Phase_Seg1) - 1` (`1..16 TQ`) |
| `0x04` | `TX_CTRL` | R/W | `[7]` `IDE` (`0`=Std, `1`=Ext), `[6]` `RTR` (`0`=Data, `1`=Remote), `[3:0]` `DLC` (`0..8`) |
| `0x05` | `TX_ID0` | R/W | Base ID `[10:3]` (CAN 2.0B `ID[28:21]`) |
| `0x06` | `TX_ID1` | R/W | `[7:5]` Base ID `[2:0]` (`ID[20:18]`), `[4:0]` Ext ID `[17:13]` |
| `0x07` | `TX_ID2` | R/W | Ext ID `[12:5]` |
| `0x08` | `TX_ID3` | R/W | `[7:3]` Ext ID `[4:0]`, `[2:0]` reserved (`3'b000`) |
| `0x09–0x10` | `TX_DATA[0..7]` | R/W | 8-byte transmit payload buffer (`0x09` = Byte 0 ... `0x10` = Byte 7) |
| `0x11` | `RX_CTRL` | R | `[7]` `IDE`, `[6]` `RTR`, `[3:0]` `DLC` |
| `0x12` | `RX_ID0` | R | Received Base ID `[10:3]` (`ID[28:21]`) |
| `0x13` | `RX_ID1` | R | `[7:5]` Received Base ID `[2:0]` (`ID[20:18]`), `[4:0]` Received Ext ID `[17:13]` |
| `0x14` | `RX_ID2` | R | Received Ext ID `[12:5]` |
| `0x15` | `RX_ID3` | R | `[7:3]` Received Ext ID `[4:0]`, `[2:0]` reserved |
| `0x16–0x1D` | `RX_DATA[0..7]` | R | 8-byte receive payload buffer (`0x16` = Byte 0 ... `0x1D` = Byte 7) |
| `0x1E` | `ACR_BASE` | R/W | Acceptance Code Register for Base ID `[10:3]` |
| `0x1F` | `AMR_BASE` | R/W | Acceptance Mask Register for Base ID `[10:3]` (`1` = don't care) |

---

### 7. `ring_oscillator.v` — Process Characterization Monitor
- **Role**: Wafer speed corner monitor (FF, TT, SS) for testing fabricated silicon in the lab.
- **Functionality**: Has zero functional role in CAN communication. The CAN controller is entirely clocked by the external `clk` pin.

---

## 6. Coding & Synthesis Guidelines for Collaboration

1. **Strict Verilog-2001 Compliance**:
   - Use standard `wire`, `reg`, `always @(posedge clk or negedge rst_n)`, and `always @*`.
   - **Do NOT use SystemVerilog keywords**: avoid `logic`, `always_ff`, `always_comb`, `typedef`, `enum`, `struct`, or `package`.
   - State encodings must be declared via `localparam`:
     ```verilog
     localparam S_IDLE = 5'd0;
     localparam S_SOF  = 5'd1;
     // ...
     reg [4:0] state, next_state;
     ```
2. **No Latch Inference**: Every `always @*` block must assign all outputs in every branch.
3. **Zero Tie-Cell Invariant (SCL CP8D Requirement)**:
   - On SCL CP8D, TritonRoute fails pin access on `VDDCON` and `VSSCON` tie-cells.
   - The design must have **0 `VDDCON`**, **0 `VSSCON`**, and **0 `XOR300`**.
   - **Never run `hilomap`** in the synthesis script. Constants must be initialized via `setundef -zero` and registered.

---

## 7. Simulation & Synthesis Commands

### Pre-Layout Simulation (Icarus Verilog)
```bash
iverilog -o tb_can_top.vvp tb_can_top.v can_top.v can_fsm.v can_btl.v \
         can_crc15.v can_bit_stuff.v can_error.v can_reg_bank.v ring_oscillator.v
vvp tb_can_top.vvp
```

### Synthesis (Yosys — Zero Tie-Cell Compliant)
```bash
yosys -p "
read_liberty -lib $PDK_ROOT/scl_cp8d/libs.ref/digital_cp8d/lib/cp8d_core_typ.lib;
read_verilog -DSYNTHESIS can_btl.v can_crc15.v can_bit_stuff.v can_error.v can_fsm.v can_reg_bank.v ring_oscillator.v can_top.v;
hierarchy -top can_top;
proc; opt; fsm; opt; memory; opt;
techmap; opt;
dfflibmap -liberty $PDK_ROOT/scl_cp8d/libs.ref/digital_cp8d/lib/cp8d_core_typ.lib;
abc -liberty $PDK_ROOT/scl_cp8d/libs.ref/digital_cp8d/lib/cp8d_core_typ.lib;
opt; clean;
setundef -zero;
opt_clean;
write_verilog can_top_sys.v;
"
```

---

## 8. Target Specifications

| Parameter | Value |
| :--- | :--- |
| **Process** | SCL CP8D 0.8µm CMOS, 2 Metal Layers |
| **Die Size** | 5,000 µm × 5,000 µm (`frame5mmx5mm.gds`) |
| **Core Area** | 4,000 µm × 4,000 µm |
| **Target Clock** | 10 MHz system clock (100 ns period) |
| **CAN Bit Rate** | 500 kbit/s reliable operating point at 10 MHz (16/20 MHz for 1 Mbit/s) |
| **Standard** | Bosch CAN 2.0A (11-bit ID) + CAN 2.0B (29-bit extended ID) |
| **Host Interface** | 32-register memory-mapped (`Addr[4:0]`, 8-bit data bus) |
| **Acceptance Filter** | Hardware ID mask filter (ACR_BASE + AMR_BASE registers) |
| **CRC** | CAN CRC-15 (polynomial `0x4599`) |
| **Error Handling** | Full fault confinement — Active / Passive / Bus-Off |
| **Wafer Tap** | Integrated ring oscillator process monitor |

---

## 9. File List

All files in this directory match the naming convention of `can_controller/1_RTL/`:

| File | Module | Description | Status |
| :--- | :--- | :--- | :--- |
| `can_top.v` | `can_top` | Top-level integration & acceptance filter | 🔲 Skeleton ready |
| `can_btl.v` | `can_btl` | Bit Timing Logic (BTL) & sample point generator | 🔲 Skeleton ready |
| `can_crc15.v` | `can_crc15` | Bosch CAN CRC-15 LFSR calculation engine | 🔲 Skeleton ready |
| `can_bit_stuff.v` | `can_bit_stuff` | Bit stuffing (TX) & destuffing / error check (RX) | 🔲 Skeleton ready |
| `can_error.v` | `can_error` | Fault confinement & error counters (TEC/REC) | 🔲 Skeleton ready |
| `can_fsm.v` | `can_fsm` | Protocol state machine (arbitration, framing, errors) | 🔲 Skeleton ready |
| `can_reg_bank.v` | `can_reg_bank` | 32-register host interface & buffers | 🔲 Skeleton ready |
| `ring_oscillator.v` | `ring_oscillator` | Wafer speed characterization test structure | 🔲 Skeleton ready |
