/*
 * AT86RF215 2.4 GHz I/Q radio mode bring-up over SPI
 * Target: Raspberry Pi Pico 2 / pico2-ice (RP2350), pico-sdk 2.x
 *
 * =====================================================================
 *  WIRING: RP2350 GPIO  <-->  AT86RF215 (48-pin QFN pin numbers)
 * =====================================================================
 *
 *  Pico GPIO        Radio pin name / pin #     Notes
 *  ---------------  -------------------------  -------------------------
 *  GP18 (SPI0 SCK)  SCLK  (pin 41)             SPI mode 0 (CPOL=0,CPHA=0)
 *  GP19 (SPI0 TX)   MOSI  (pin 43)             Pico -> radio
 *  GP16 (SPI0 RX)   MISO  (pin 44)             Radio -> Pico
 *  GP17 (GPIO)      SELN  (pin 42)             Active low. Driven by hand
 *                                              (not by the SPI block) so it
 *                                              stays low for all 3 bytes.
 *  GP20 (GPIO)      RSTN  (pin 13)             Active low hardware reset
 *  GP21 (GPIO in)   IRQ   (pin 40)             Optional here: this code
 *                                              polls RF24_IRQS over SPI
 *                                              instead of using the pin.
 *  GND              DVSS / AVSS                Common ground, mandatory.
 *
 *  Power (not from this code): EVDD and DEVDD (pins 15/21/29/39/46) must
 *  be tied together at ~3.0 V typ. with decoupling close to the chip. The
 *  datasheet lists 3.0 V typical; check its absolute max / VIH limits
 *  before wiring 3.3 V Pico GPIOs directly (I did not verify these).
 *  Also needs the 26 MHz crystal (XTAL pins 17/18) or TCXO on pin 17.
 *
 *  Not connected to the RP2350 (LVDS I/Q data path, goes to your FPGA /
 *  baseband, e.g. the iCE40 on the pico2-ice):
 *    TXDP/TXDN     (pins 28/27)  FPGA -> radio  I/Q data (TX)
 *    TXCLKP/TXCLKN (pins 26/25)  FPGA -> radio  TX clock
 *    RXCLKP/RXCLKN (pins 34/33)  radio -> FPGA  RX clock (radio is master)
 *    RXDP24/RXDN24 (pins 36/35)  radio -> FPGA  2.4 GHz I/Q data (RX)
 *  These are differential pairs; use matched traces and 100 ohm
 *  termination at the receiving end. Check that your FPGA pins support
 *  LVDS in/out at the levels you need.
 *
 *  GPIO numbers above are my defaults. Check the pico2-ice pinout and
 *  change the #defines below if those pins are not broken out.
 *
 * =====================================================================
 *  SPI frame (datasheet Table 4-4):
 *    write: [0x80 | addr[13:8]] [addr[7:0]] [data ...]
 *    read : [0x00 | addr[13:8]] [addr[7:0]] [dummy] -> data on MISO
 * =====================================================================
 */

#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>
#include "pico/stdlib.h"
#include "hardware/spi.h"

/* ---------------- Pin / SPI configuration ---------------- */
#define SPI_PORT      spi0
#define PIN_MISO      14
#define PIN_SELN      16
#define PIN_SCK       15
#define PIN_MOSI      17
#define PIN_RSTN      20
#define PIN_IRQ       24
#define SPI_BAUD_HZ   1000000   /* datasheet max is 25 MHz; 1 MHz is easy to debug */

/* ---------------- Register addresses ---------------- */
#define RF_RST        0x0005
#define RF_IQIFC0     0x000A
#define RF_IQIFC1     0x000B
#define RF_IQIFC2     0x000C
#define RF_PN         0x000D
#define RF_VN         0x000E

#define RF09_IRQS     0x0000
#define RF24_IRQS     0x0001

#define RF24_IRQM     0x0200
#define RF24_STATE    0x0202
#define RF24_CMD      0x0203
#define RF24_CS       0x0204
#define RF24_CCF0L    0x0205
#define RF24_CCF0H    0x0206
#define RF24_CNL      0x0207
#define RF24_CNM      0x0208
#define RF24_RXBWC    0x0209
#define RF24_RXDFE    0x020A
#define RF24_AGCC     0x020B
#define RF24_TXCUTC   0x0212
#define RF24_TXDFE    0x0213
#define RF24_PAC      0x0214

/* ---------------- Commands / states / bits ---------------- */
#define CMD_NOP       0x0
#define CMD_SLEEP     0x1
#define CMD_TRXOFF    0x2
#define CMD_TXPREP    0x3
#define CMD_TX        0x4
#define CMD_RX        0x5
#define CMD_RESET     0x7

#define STATE_TRXOFF  0x2
#define STATE_TXPREP  0x3
#define STATE_TX      0x4
#define STATE_RX      0x5

#define IRQ_WAKEUP    (1u << 0)
#define IRQ_TRXRDY    (1u << 1)
#define IRQ_IQIFSF    (1u << 5)

/* IQIFC1.CHPM: 1 = both radios in I/Q mode (what the TX/RX procedures in
 * the datasheet use); 5 = only RF24 in I/Q mode, BBC0/RF09 in baseband.
 * (AT86RF215IQ only supports 1.) */
#define CHPM          0x1
#define SKEWDRV_DEF   0x2

/* ---------------- Example RF settings (tune for your signal) ---------------- */
#define CENTER_FREQ_KHZ  2450000u  /* 2.45 GHz, must be 2400000..2483500 */
#define TXCUTC_VAL       0x0B      /* PARAMP=4us, LPFCUT=1000 kHz */
#define TXDFE_VAL        0x81      /* RCUT=1.0*fs/2, SR=1 (fs=4 MHz) */
#define PAC_VAL          0x70      /* PACUR=3, TXPWR=16 (mid power; 0x7F = max) */
#define RXBWC_VAL        0x0B      /* BW=2000 kHz, IF=2000 kHz (reset default) */
#define RXDFE_VAL        0x81      /* RCUT=1.0*fs/2, SR=1 (fs=4 MHz) */
#define AGCC_VAL         0x81      /* AGC enabled (reset default) */

/* ---------------- I/Q interface options (RF_IQIFC0) ---------------- */

/* 1 = set IQIFC0.EXTLB. The radio loops the TXD input back onto RXD24, so you
 *     can test the FPGA <-> radio LVDS link with no RF at all (datasheet 4.5.7).
 *     In this mode main() never sends the TX command and only goes to
 *     TXPREP/RX, so nothing is transmitted.
 * 0 = normal operation. Do NOT leave loopback on for real transmissions. */
#ifndef IQ_LOOPBACK_TEST
#define IQ_LOOPBACK_TEST   1
#endif

/* 1 = set IQIFC0.CMV1V2: LVDS levels with 1.2 V common mode (IEEE 1596.3).
 *     Use this with a standard external LVDS driver/receiver chip.
 * 0 = the radio's low-swing proprietary levels (200 mV swing, 200 mV common
 *     mode; the receiver input only tolerates 0..435 mV in this mode, Table 10-32). */
#ifndef IQ_LVDS_IEEE_1V2
#define IQ_LVDS_IEEE_1V2   1
#endif

#define IQIFC0_DRV         1       /* driver current: 0=1mA 1=2mA 2=3mA 3=4mA (reset default 1) */
#define IQIFC0_CMV         1       /* common mode: 0=150..3=300 mV, ignored if CMV1V2=1 (reset default 1) */
#define IQIFC0_EEC         0       /* 1 = embedded TX start control in I_DATA[0] */

/* Reset value of IQIFC0 is 0x14. Bit 6 (SF) is read-only. */
#define IQIFC0_VAL  ( (IQ_LOOPBACK_TEST ? 0x80 : 0x00) | (IQIFC0_DRV << 4) | \
                      (IQIFC0_CMV << 2) | (IQ_LVDS_IEEE_1V2 ? 0x02 : 0x00) | IQIFC0_EEC )

/* ====================== SPI helpers ====================== */

static inline void seln(bool level) { gpio_put(PIN_SELN, level); }

static void rf_write(uint16_t addr, uint8_t val)
{
    uint8_t buf[3] = { (uint8_t)(0x80 | ((addr >> 8) & 0x3F)),
                       (uint8_t)(addr & 0xFF),
                       val };
    seln(0);
    spi_write_blocking(SPI_PORT, buf, 3);
    seln(1);
}

/* Block write: data goes to addr, addr+1, ... (SELN held low) */
static void rf_write_block(uint16_t addr, const uint8_t *data, size_t len)
{
    uint8_t hdr[2] = { (uint8_t)(0x80 | ((addr >> 8) & 0x3F)),
                       (uint8_t)(addr & 0xFF) };
    seln(0);
    spi_write_blocking(SPI_PORT, hdr, 2);
    spi_write_blocking(SPI_PORT, data, len);
    seln(1);
}

static uint8_t rf_read(uint16_t addr)
{
    uint8_t tx[3] = { (uint8_t)((addr >> 8) & 0x3F), (uint8_t)(addr & 0xFF), 0x00 };
    uint8_t rx[3] = { 0 };
    seln(0);
    spi_write_read_blocking(SPI_PORT, tx, rx, 3);
    seln(1);
    return rx[2];
}

/* ====================== Radio helpers ====================== */

/* Reading RFn_IRQS clears the bits, so OR everything seen into *seen. */
static bool wait_irq24(uint8_t mask, uint32_t timeout_ms, uint8_t *seen)
{
    absolute_time_t end = make_timeout_time_ms(timeout_ms);
    uint8_t acc = 0;
    while (!time_reached(end)) {
        acc |= rf_read(RF24_IRQS);
        if ((acc & mask) == mask) {
            if (seen) *seen = acc;
            return true;
        }
        sleep_us(200);
    }
    if (seen) *seen = acc;
    return false;
}

static void rf24_cmd(uint8_t cmd) { rf_write(RF24_CMD, cmd); }

static void fail(const char *msg)
{
    printf("ERROR: %s\n", msg);
    while (true) tight_loop_contents();
}

/* IEEE channel scheme, CN=0: f = CCF0 * 25 kHz + 1.5 GHz.
 * Writes CS, CCF0L, CCF0H, CNL, CNM in one block; CNM last latches it. */
static void rf24_set_frequency(uint32_t freq_khz)
{
    if (freq_khz < 2400000u || freq_khz > 2483500u)
        fail("frequency out of 2.4 GHz range");

    uint16_t ccf0 = (uint16_t)((freq_khz - 1500000u) / 25u);   /* 2450000 -> 38000 = 0x9470 */
    uint8_t blk[5] = {
        0x08,                    /* RF24_CS   : 200 kHz spacing (unused when CN=0) */
        (uint8_t)(ccf0 & 0xFF),  /* RF24_CCF0L */
        (uint8_t)(ccf0 >> 8),    /* RF24_CCF0H */
        0x00,                    /* RF24_CNL  : channel number 0 */
        0x00,                    /* RF24_CNM  : CM=0 (IEEE), CNH=0. Must be last. */
    };
    rf_write_block(RF24_CS, blk, sizeof blk);
}

static void rf_reset_and_wait(void)
{
    uint8_t seen;

    /* Hardware reset pulse, then software chip reset (80 05 07). */
    gpio_put(PIN_RSTN, 0);
    sleep_ms(1);
    gpio_put(PIN_RSTN, 1);
    sleep_ms(5);

    rf_write(RF_RST, CMD_RESET);

    /* Both transceivers raise WAKEUP; read both IRQS regs to clear. */
    if (!wait_irq24(IRQ_WAKEUP, 100, &seen))
        fail("no WAKEUP after reset (check wiring, power, 26 MHz clock)");
    (void)rf_read(RF09_IRQS);
}

static void rf_configure_iq_24ghz(void)
{
    /* Chip mode: I/Q radio mode */
    rf_write(RF_IQIFC1, (uint8_t)((CHPM << 4) | SKEWDRV_DEF));

    /* I/Q interface electrical levels, loopback enable, embedded TX control */
    rf_write(RF_IQIFC0, (uint8_t)IQIFC0_VAL);

    /* Enable all radio IRQs for RF24 */
    rf_write(RF24_IRQM, 0x3F);

    /* TX frontend */
    rf_write(RF24_TXCUTC, TXCUTC_VAL);
    rf_write(RF24_TXDFE,  TXDFE_VAL);
    rf_write(RF24_PAC,    PAC_VAL);

    /* RX frontend */
    rf_write(RF24_RXBWC,  RXBWC_VAL);
    rf_write(RF24_RXDFE,  RXDFE_VAL);
    rf_write(RF24_AGCC,   AGCC_VAL);

    /* Channel */
    rf24_set_frequency(CENTER_FREQ_KHZ);
}

/* ---- State changes ---- */

static void rf24_enter_txprep(void)
{
    uint8_t seen;
    rf24_cmd(CMD_TXPREP);
    if (!wait_irq24(IRQ_TRXRDY, 50, &seen))
        fail("no TRXRDY after TXPREP");
}

/* Call after your FPGA is streaming I/Q words (including the sync pattern)
 * to the radio TXD pins. Check IQIFC2.SYNC first if you can. */
static void rf24_start_rx(void)
{
    rf24_cmd(CMD_RX);
    sleep_us(200);
    /* Datasheet: freeze the AGC after the preamble to stop gain changes:
     *   rf_write(RF24_AGCC, AGCC_VAL | 0x02);   // FRZC=1
     * and release afterwards:
     *   rf_write(RF24_AGCC, AGCC_VAL);          // FRZC=0
     */
}

/* TX with IQIFC0.EEC=0: the FPGA must already be sending zero samples
 * (for PA ramp-up) followed by I/Q samples. Timing between this command
 * and the sample stream matters (datasheet 6.1.4). */
static void rf24_start_tx(void)
{
    rf24_cmd(CMD_TX);
}

/* Stop TX or RX: go back to TXPREP, wait for TRXRDY. For TX, keep sending
 * padding samples until the PA has ramped down before calling this. */
static void rf24_stop(void)
{
    rf24_enter_txprep();
}

/* ====================== I/Q link status ====================== */

/* IQIFC2.SYNC (bit 7) is cleared by every read and set again when the next
 * valid I/Q word arrives, so poll it for a short while rather than reading once. */
static bool iq_wait_sync(uint32_t timeout_ms)
{
    absolute_time_t end = make_timeout_time_ms(timeout_ms);
    while (!time_reached(end)) {
        if (rf_read(RF_IQIFC2) & 0x80) return true;
        sleep_us(100);
    }
    return false;
}

/* Prints the radio's view of the I/Q link:
 *   SF      = IQIFC0 bit 6: synchronization failure
 *   FAILSF  = IQIFC1 bit 7: receiver fail-safe (no driver connected to TXD/TXCLK)
 *   SYNC    = radio is receiving valid I/Q words from the FPGA
 *   IQIFSF  = RF24_IRQS bit 5: sync failure interrupt (reading IRQS clears it) */
static void iq_print_status(const char *tag)
{
    uint8_t c0   = rf_read(RF_IQIFC0);
    uint8_t c1   = rf_read(RF_IQIFC1);
    bool    sync = iq_wait_sync(20);
    uint8_t irq  = rf_read(RF24_IRQS);
    printf("[%-9s] IQIFC0=0x%02X SF=%u | IQIFC1=0x%02X FAILSF=%u | SYNC=%u | IRQS=0x%02X IQIFSF=%u | state=0x%X\n",
           tag, c0, (c0 >> 6) & 1, c1, (c1 >> 7) & 1, sync ? 1 : 0, irq,
           (irq >> 5) & 1, rf_read(RF24_STATE) & 0x07);
}

/* ====================== main ====================== */

int main(void)
{
    stdio_init_all();
    sleep_ms(2000);   /* give USB serial time to enumerate */

    /* GPIO setup */
    gpio_init(PIN_SELN); gpio_set_dir(PIN_SELN, GPIO_OUT); gpio_put(PIN_SELN, 1);
    gpio_init(PIN_RSTN); gpio_set_dir(PIN_RSTN, GPIO_OUT); gpio_put(PIN_RSTN, 1);
    gpio_init(PIN_IRQ);  gpio_set_dir(PIN_IRQ,  GPIO_IN);

    /* SPI setup: mode 0, MSB first, 8-bit */
    spi_init(SPI_PORT, SPI_BAUD_HZ);
    spi_set_format(SPI_PORT, 8, SPI_CPOL_0, SPI_CPHA_0, SPI_MSB_FIRST);
    gpio_set_function(PIN_SCK,  GPIO_FUNC_SPI);
    gpio_set_function(PIN_MOSI, GPIO_FUNC_SPI);
    gpio_set_function(PIN_MISO, GPIO_FUNC_SPI);

    rf_reset_and_wait();

    uint8_t pn = rf_read(RF_PN);
    uint8_t vn = rf_read(RF_VN);
    printf("RF_PN=0x%02X (0x34=AT86RF215, 0x35=IQ, 0x36=M), RF_VN=0x%02X\n", pn, vn);
    if (pn != 0x34 && pn != 0x35)
        fail("unexpected part number, SPI wiring/mode problem?");

    rf_configure_iq_24ghz();
    printf("IQIFC1=0x%02X\n", rf_read(RF_IQIFC1));

    rf24_enter_txprep();
    printf("State=0x%X (3 = TXPREP)\n", rf_read(RF24_STATE) & 0x07);

    /* In TXPREP the radio starts RXCLK and expects the FPGA to send I/Q words
     * on TXD/TXCLK. The first frame starts with zero words, so the radio can
     * synchronize. SYNC=1 and SF=0 mean the FPGA -> radio link works. */
    iq_print_status("TXPREP");

#if IQ_LOOPBACK_TEST
    /* Loopback test (EXTLB=1): the FPGA's status LEDs show whether the words
     * come back intact:  led_clk blinking = RXCLK present, led_lock = word
     * alignment found, led_ok = >=1024 good words, led_err = bad word seen.
     *
     * Which state enables the RXD24 driver while looping back is not spelled
     * out in the datasheet (RX link is listed under state RX, TX link under
     * TXPREP/TX), so try both: stay in TXPREP first, then switch to RX. Note
     * which one lights led_ok. Neither state transmits RF (no TX command). */
    sleep_ms(1000);
    iq_print_status("TXPREP+1s");

    rf24_cmd(CMD_RX);
    sleep_ms(2);
    iq_print_status("RX");
    sleep_ms(1000);
    iq_print_status("RX+1s");

    rf24_stop();   /* back to TXPREP, waits for TRXRDY */
    printf("Done. Set IQ_LOOPBACK_TEST to 0 for normal operation.\n");
#else
    /* Normal operation demo: receive for a second, then stop. */
    rf24_start_rx();
    printf("State=0x%X (5 = RX)\n", rf_read(RF24_STATE) & 0x07);
    sleep_ms(1000);
    rf24_stop();
    printf("State=0x%X (3 = TXPREP)\n", rf_read(RF24_STATE) & 0x07);
#endif

    (void)rf24_start_tx;   /* see comment above before using */

    while (true) tight_loop_contents();
}
