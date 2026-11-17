/*
 * MIT License
 *
 * Copyright (c) 2023 tinyVision.ai
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */


#include <stdio.h>
#include "pico/stdlib.h"
#include "pico/stdio.h"
#include "boards.h"
#include "ice_cram.h"
#include "ice_fpga.h"
#include "ice_led.h"


uint8_t bitstream[] = {
#include "bitstream.h"
};

int main(void) {
    ice_led_init();
    ice_fpga_init(FPGA_DATA, ICE_FPGA_DEFAULT_FREQUENCY);
    ice_fpga_start(FPGA_DATA);

    stdio_init_all();

    printf("Press any key to enable the light\n");
    char ch = getchar(); // Blocks until a character arrives over USB
    printf("You typed: %c\n", ch);

    // Write the whole bitstream to the FPGA CRAM
    ice_cram_open(FPGA_DATA);
    ice_cram_write(bitstream, sizeof(bitstream));
    ice_cram_close();
    
    while (1) {
        sleep_ms(1000);
        printf("IO is working! \n");
    }
    return 0;
}
