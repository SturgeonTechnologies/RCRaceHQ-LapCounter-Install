# Lap counter hardware: BOM and wiring

Everything needed to build one lap counter kit (one per track), plus the
burst-detector HAT and how it is wired.

The HAT design files (KiCad, gerbers, JLCPCB BOM/CPL, schematic PDF) live in the
app repo:
[RCRaceHQ-LapCounter-HAT/burst-detector-hat](https://github.com/SturgeonTechnologies/RCRaceHQ-LapCounter-HAT/tree/main/burst-detector-hat).
Part values below are copied from its `tools/design.py`, which generates the
schematic, board and BOM. If they ever disagree, `design.py` wins.

> **Status (2026-10-30):** the Pi + RTL-SDR + loop path works (transponder
> learned and recorded on a test Pi). The HAT circuit has **not** been built
> or tested yet, the LCSC part numbers have not been checked against stock, and
> the PoE header position is assumed, not measured. Order the kit parts freely;
> treat the HAT as a first prototype run (or breadboard it first, see below).

- [1. Kit BOM (off the shelf)](#1-kit-bom-off-the-shelf)
- [2. Burst-detector HAT BOM](#2-burst-detector-hat-bom)
- [3. Breadboard prototype (optional)](#3-breadboard-prototype-optional)
- [4. System wiring](#4-system-wiring)
- [5. HAT schematic (ASCII)](#5-hat-schematic-ascii)
- [6. Pi header pins used](#6-pi-header-pins-used)
- [7. Bring-up checks](#7-bring-up-checks)

---

## 1. Kit BOM (off the shelf)

Quantities are per kit.

### Required

| Qty | Part | Notes |
|---|---|---|
| 1 | Raspberry Pi 4 Model B, 2 GB or more | Kit baseline. Pi OS Trixie 64-bit or Ubuntu 24.04 arm64 both work with these playbooks |
| 1 | USB-C power supply, 5.1 V 3 A (official Pi 4 PSU) | Skip if using a PoE HAT (see optional) |
| 1 | microSD card, 32 GB, A1/A2 class | Holds the OS, Docker images, SQLite and `.rc4` files |
| 1 | RTL-SDR Blog V3 dongle | 5 MHz via Q-branch direct sampling (OpenStint switches this on by itself). The V4 also works |
| 1 | USB-A extension, 15–30 cm (male to female) | Keeps the dongle away from the Pi and off the HAT. Less noise, less heat |
| 1 | Ethernet cable | `eth0` is the internet uplink by default |
| 1 | Case that fits a HAT, or open frame with standoffs | The HAT needs clearance above the 40-pin header and two SMA jacks on the left edge |

### Track loop

| Qty | Part | Notes |
|---|---|---|
| 1 | Speaker wire, 2-conductor, 16–18 AWG | Length = track width + lead to the balun. A 15 m (50 ft) spool covers most club tracks |
| 1 | Resistor, 470 Ω, 1/2 W or more | Terminates the far end of the loop. 330–470 Ω per OpenStint's setup guide |
| 1 | 1:9 HF balun/unun (1–30 MHz) | Near end of the loop. Most have an SO-239 (UHF) jack |
| 1 | Coax, balun to Pi, with **PL-259 → SMA male** ends | RG-58 for long runs, RG-316 for short ones. Length = balun to where the Pi sits. Add an adapter if your balun has BNC or SMA |
| 1 | Weatherproof box or tape for the balun + termination | Outdoor tracks |

Loop layout (from OpenStint `docs/setup-tutorial.md`): split the pair so the two
wires run across the track about 30 cm apart, terminate the far end with the
resistor, and connect the near end to the balun.

### With the HAT (burst detector)

| Qty | Part | Notes |
|---|---|---|
| 1 | Burst-detector HAT PCB, assembled | See [section 2](#2-burst-detector-hat-bom) |
| 1 | 2×20 stacking header, 2.54 mm, long pins (~11 mm) | Hand-soldered as J3. Lets another HAT stack on top |
| 1 | 2×2 stacking header, 2.54 mm (optional) | J4, only if a PoE HAT has to stack above this one |
| 4 | M2.5 standoffs, 11 mm (male-female or female-female) + 8 M2.5×6 screws | Standard HAT spacing |
| 1 | SMA male to SMA male cable, 15–30 cm (RG-316) | HAT J2 "TO SDR" → RTL-SDR antenna jack |

Without the HAT, the loop coax goes straight into the RTL-SDR (this is how the test Pi
runs today).

### Optional

| Qty | Part | Notes |
|---|---|---|
| 1 | Powered speaker / PA with 3.5 mm input | Announcer. HDMI carries the same audio |
| 1 | Raspberry Pi PoE+ HAT + PoE switch/injector | One cable for power + network. **Stacking order with the burst HAT isn't decided yet**, so hold off unless you want to experiment |

### Not yet, don't order

- **Learning pad + GPIO RF relay (SPDT):** not designed yet. For now, learn on
  the track loop.

---

## 2. Burst-detector HAT BOM

65 × 56.5 mm Pi 4 HAT, 2 layers, 1.6 mm, HASL. All SMD parts are top side.

**Ordering at JLCPCB** (files in the app repo under `hardware/burst-detector-hat/fab/`):

1. Upload `burst_detector_hat_gerbers.zip`. Keep the defaults: 2 layers, 1.6 mm, HASL.
2. Turn on **PCB Assembly**, top side. Upload `bom_jlcpcb.csv` and `cpl_jlcpcb.csv`.
3. In the parts review, confirm every LCSC number is in stock. Swap any that
   aren't for the same value and package.
4. In the 3D/placement preview, check pin 1 of **U1, U2, U3** lines up with the
   dot on the silkscreen. Fix the rotation there if it doesn't.
5. J3, J4, the mounting holes and the test points are not assembled. Solder J3 yourself.

| Ref | Value | Package | LCSC | What it does |
|---|---|---|---|---|
| J1 | SMA, edge mount | Amphenol 132289 | C3172723 | LOOP IN (from the balun) |
| J2 | SMA, edge mount | Amphenol 132289 | C3172723 | TO SDR (to the RTL-SDR) |
| D2 | PESD5V0S1BA | SOD-323 | C19224 | ESD/TVS clamp on the loop input |
| R10, R11, R12 | 16.5 Ω | 0603 | C12054 | 3-way 50 Ω resistive splitter |
| C10, C11 | 1 nF C0G | 0603 | C1636 | 3 MHz high-pass, series caps |
| L10 | 1.5 µH | 1206 | C2885920 | 3 MHz high-pass, shunt inductor |
| C12, C13 | 390 pF C0G | 0603 | C1667 | 8 MHz low-pass, shunt caps |
| L11 | 2.2 µH | 1206 | C1048 | 8 MHz low-pass, series inductor |
| R13 | 52.3 Ω | 0603 | C81321 | 50 Ω termination into the detector |
| C2, C3 | 10 nF | 0603 | C1589 | AD8307 input coupling |
| U1 | AD8307ARZ | SOIC-8 | C495272 | Log detector, RSSI out at 25 mV/dB |
| R20 | 10 Ω | 0603 | C22859 | 5 V filter for the AD8307 |
| C20, C30, C31, C40 | 100 nF | 0603 | C1591 | Decoupling (U1, U2, threshold, U3) |
| C21 | 10 µF | 0805 | C15850 | 5 V_A bulk |
| C22 | 1 nF | 0603 | C1636 | AD8307 offset (OFS) cap |
| C23 | 470 pF C0G | 0603 | C36252 | RSSI smoothing |
| U2 | LM393DR2G | SOIC-8 | C7955 | Comparator A = burst out, B = LED driver |
| R3, R5, R6, R7 | 10 kΩ | 0603 | C25804 | Comparator input, pull-up, LED reference divider |
| R4 | 1 MΩ | 0603 | C22935 | Hysteresis |
| R8 | 1 kΩ | 0603 | C21190 | LED current |
| D1 | Green LED | 0603 | C12624 | BURST indicator |
| RV1 | 10 kΩ trimmer | Bourns TC33X | C719176 | Detection threshold |
| U3 | ADS1115IDGSR | MSOP-10 | C37593 | 16-bit ADC, I2C 0x48: RSSI + threshold |
| J3 | 2×20 stacking header | 2.54 mm | hand solder | Pi GPIO |
| J4 | 2×2 header | 2.54 mm | hand solder, optional | PoE pass-through, not connected |
| TP1–TP4 | Test pads | 1.5 mm | — | RSSI, THRESH, BURST, GND |

---

## 3. Breadboard prototype (optional)

The HAT is untested. If you want to prove the circuit before paying for
assembly, this is the same circuit in through-hole/breakout form (values as in
[section 2](#2-burst-detector-hat-bom)):

| Qty | Part | Notes |
|---|---|---|
| 2 | AD8307ARZ (SOIC-8) | Only sold as SOIC. One spare in case of a bad solder job |
| 2 | SOIC-8 to DIP-8 adapter board | Solder the AD8307 onto this so it fits a breadboard |
| 1 | LM393N (DIP-8) | Same part as U2 in a breadboard package |
| 1 | ADS1115 breakout (Adafruit 1085 or clone) | Has its own pull-ups and decoupling; set ADDR to GND for 0x48 |
| 1 | 10 kΩ trimpot, breadboard type | RV1 |
| 2 | SMA female, PCB or panel mount, with short pigtail | J1 / J2 |
| — | Resistors: 16.5 Ω ×3 (or 15 Ω + 1.5 Ω), 52.3 Ω (or 51 Ω), 10 Ω, 1 kΩ, 10 kΩ ×4, 1 MΩ | 1/4 W metal film |
| — | Capacitors: 390 pF C0G ×2, 470 pF C0G, 1 nF C0G ×3, 10 nF ×2, 100 nF ×4, 10 µF | Ceramic; C0G/NP0 where marked |
| — | Inductors: 1.5 µH, 2.2 µH | Axial or radial, rated for a few MHz |
| 1 | Green LED (3 or 5 mm) | D1 |
| 1 | Breadboard + jumper wires + female-to-male Dupont leads | To the Pi header |

Keep the RF part (splitter → filter → AD8307) short and close together on the
breadboard, with a solid ground rail. Long jumpers at 5 MHz will pick up noise.

---

## 4. System wiring

```
                         TRACK (top view)
   ┌──────────────────────────────────────────────────────┐
   │   wire A  ═══════════════════════════════════════╗   │
   │                     ~30 cm apart                  [R] 470 Ω termination
   │   wire B  ═══════════════════════════════════════╝   │
   └───╥──────────────────────────────────────────────────┘
       ║  speaker-wire pair (near end)
   ┌───╨────┐
   │ 1:9    │ SO-239
   │ balun  ├────────────── coax (RG-58 / RG-316) ───────────────┐
   └────────┘          PL-259 ........................ SMA male  │
                                                                 │
   ┌─────────────────────────── Raspberry Pi 4 ──────────────────┼───────────┐
   │                                                             │           │
   │   ┌──────────── burst-detector HAT (on the 40-pin) ─────────┼────────┐  │
   │   │                                                         v        │  │
   │   │  J1 LOOP IN (SMA) ──► splitter ──┬──► J2 TO SDR (SMA) ──┐        │  │
   │   │                                  └──► filter ► AD8307   │        │  │
   │   │                                       ► LM393 ► GPIO17  │        │  │
   │   │                                       ► ADS1115 ► I2C   │        │  │
   │   └─────────────────────────────────────────────────────────┼────────┘  │
   │                                                    SMA–SMA  │ cable     │
   │                                                             v           │
   │   USB ◄── 15–30 cm USB extension ◄── RTL-SDR Blog V3 (antenna SMA)      │
   │                                                                         │
   │   eth0 ◄── Ethernet (internet uplink)                                   │
   │   wlan0 ──► "RC Race Event" hotspot (phones, captive portal)            │
   │   3.5 mm / HDMI ──► speaker / PA (announcer)                            │
   │   USB-C ◄── 5.1 V 3 A PSU (or PoE+ HAT)                                 │
   └─────────────────────────────────────────────────────────────────────────┘

   Without the HAT: the loop coax goes straight into the RTL-SDR's SMA jack.
```

---

## 5. HAT schematic (ASCII)

Pin numbers in brackets. Grounds marked `⏚`.

### 5.1 Input protection, splitter, band-pass filter

```
 J1 LOOP IN                R10 16.5Ω            R11 16.5Ω
 (SMA centre) ── LOOP ──┬───/\/\/─── SPLIT ──┬───/\/\/─────────────► J2 TO SDR (SMA centre)
                        │                     │
                  D2 PESD5V0S1BA         R12 16.5Ω
                        │                     │
                        ⏚                   RF_A
                                              │
   ┌──────────────────────────────────────────┘
   │
   │      3 MHz high-pass (T)                 8 MHz low-pass (pi)        50 Ω load
   │
   └─ RF_A ──┤├──── HP1 ────┤├──── HP2 ──────(((((────── RF_F ──┬───────────┤├───► U1 INP [8]
            C10      │     C11      │       L11 2.2µH           │         C2 10n
            1n C0G   │     1n C0G   │                           │
                  L10 1.5µH     C12 390p C0G          C13 390p C0G ── ⏚
                     │              │                           │
                     ⏚              ⏚                     R13 52.3Ω ── ⏚

   J1 and J2 shields ── ⏚
```

### 5.2 AD8307 log detector (U1) and power filter

```
                         +5V (Pi pins 2, 4)
                           │
                        R20 10Ω
                           │
                         +5V_A ──┬──── C20 100n ── ⏚
                           │     └──── C21 10µ  ── ⏚
                           │
               ┌───────────┴─────────────┐
     INP ──────┤[8] INP           VPS [6]├── +5V_A
               │                  ENB [5]├── +5V_A
   C3 10n ─────┤[1] INM                  │
   (to ⏚)      │                  INT [7]├── n/c
               │        AD8307           │
       ⏚ ──────┤[2] COM                  │
               │                  OUT [4]├──── RSSI ──┬── C23 470p ── ⏚
   C22 1n ─────┤[3] OFS                  │            ├── TP1
   (to ⏚)      └─────────────────────────┘            ├── U3 AIN0 [4]
                                                      └── R3 10k ──► CMP_P (5.3)
   RSSI ≈ 25 mV/dB, roughly 0.3–2.5 V
```

### 5.3 Threshold, comparator (U2 LM393), LED

```
   +3V3 ── RV1 10k trimmer [3]
                │
              wiper [2] ── THRESH ──┬── C31 100n ── ⏚
                │                   ├── TP2
   ⏚ ── RV1 [1] ┘                   ├── U3 AIN1 [5]
                                    └── U2 IN-A [2]

                 R3 10k                                  +3V3
   RSSI ───────/\/\/──── CMP_P ──── U2 IN+A [3]            │
                           │                            R5 10k (pull-up)
                           └──── R4 1M ────┐               │
                                (hysteresis)│               │
                     U2 OUT-A [1] ──────────┴──── BURST ────┴──┬──► Pi GPIO17 (pin 11)
                     (open collector)                          ├──► TP3
                                                               └──► U2 IN-B [6]

   +3V3 ── R6 10k ──┬── REF_B (1.65 V) ── U2 IN+B [5]
                    R7 10k
                    │
                    ⏚

   +3V3 ── R8 1k ── D1 green LED (A→K) ── U2 OUT-B [7]        LED on while BURST is high

   U2 VCC [8] ── +5V (C30 100n to ⏚)      U2 GND [4] ── ⏚

   BURST goes high (3.3 V) when RSSI > THRESH: about 650 pulses/s while a
   transponder is over the loop. Open-collector output pulled to 3.3 V, so it
   is safe for the Pi's GPIO even though U2 runs on 5 V.
```

### 5.4 ADS1115 ADC (U3)

```
                 ┌────────────────────────┐
     ⏚ ──────────┤[1] ADDR       VDD [8]  ├── +3V3 (C40 100n to ⏚)
     n/c ────────┤[2] ALERT/RDY  SDA [9]  ├── Pi SDA1 / GPIO2 (pin 3)
     ⏚ ──────────┤[3] GND        SCL [10] ├── Pi SCL1 / GPIO3 (pin 5)
     RSSI ───────┤[4] AIN0                │
     THRESH ─────┤[5] AIN1    ADS1115     │
     n/c ────────┤[6] AIN2                │
     n/c ────────┤[7] AIN3                │
                 └────────────────────────┘
   ADDR to GND → I2C address 0x48. The Pi's I2C pins have their own 1.8 kΩ
   pull-ups, so the HAT adds none. ALERT is unused; the Pi polls.
```

---

## 6. Pi header pins used

| Pi pin | Signal | HAT net |
|---|---|---|
| 1, 17 | 3.3 V | +3V3 (pull-ups, trimmer, ADS1115; < 2 mA) |
| 2, 4 | 5 V | +5V (LM393, AD8307 via R20) |
| 3 | GPIO2 / SDA1 | ADS1115 SDA |
| 5 | GPIO3 / SCL1 | ADS1115 SCL |
| 11 | GPIO17 | BURST (comparator out) |
| 6, 9, 14, 20, 25, 30, 34, 39 | GND | GND |

Every other pin is passed through untouched. GPIO27 (planned for the ADS1115
ALERT) and the learning-pad relay pin are not wired on this revision.

---

## 7. Bring-up checks

Enable I2C first. On Pi OS: `sudo raspi-config nonint do_i2c 0`. On Ubuntu: add
`dtparam=i2c_arm=on` to `/boot/firmware/config.txt` and reboot.

1. **Power, no loop connected:** the LED is off.
2. **I2C:** `sudo apt install -y i2c-tools && sudo i2cdetect -y 1` shows `48`.
3. **Threshold:** turn RV1 until the LED goes out with the loop empty, then back
   off a little more.
4. **Transponder on the loop:** the LED lights, and GPIO17 sees about 650 rising
   edges a second:
   ```bash
   sudo apt install -y gpiod
   timeout 1 gpiomon -c gpiochip0 -e rising 17 | wc -l   # libgpiod v2 (Trixie, Ubuntu 24.04)
   ```
5. **Decoder still works through the splitter:** `journalctl -u openstint -f -o cat`
   shows `S` lines with frames received, and `P …` passings when the car crosses.
   The splitter costs about 6 dB to the SDR, so if passings get flaky, raise the
   gain (`-g`) in `/etc/openstint.conf`.
