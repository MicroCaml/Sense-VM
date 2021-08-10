/**********************************************************************************/
/* MIT License									  */
/* 										  */
/* Copyright (c) 2021 Joel Svensson, Abhiroop Sarkar 				  */
/* 										  */
/* Permission is hereby granted, free of charge, to any person obtaining a copy	  */
/* of this software and associated documentation files (the "Software"), to deal  */
/* in the Software without restriction, including without limitation the rights	  */
/* to use, copy, modify, merge, publish, distribute, sublicense, and/or sell	  */
/* copies of the Software, and to permit persons to whom the Software is	  */
/* furnished to do so, subject to the following conditions:			  */
/* 										  */
/* The above copyright notice and this permission notice shall be included in all */
/* copies or substantial portions of the Software.				  */
/* 										  */
/* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR	  */
/* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,	  */
/* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE	  */
/* AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER	  */
/* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,  */
/* OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE  */
/* SOFTWARE.									  */
/**********************************************************************************/

#include <stdint.h>
#include <stdbool.h>

#include <drivers/gpio.h>
#include <hal/zephyr/svm_zephyr.h>

#include <ll/ll_button.h>

/* The callback routine */
void button_pressed_cb(const struct device *dev,
		       struct gpio_callback *cb,
		       uint32_t pins) {
  unsigned int key = irq_lock();

  /* This is so weird and backwards!!! CONTAINER_OF*/
  button_driver_internal_t *parent = CONTAINER_OF(cb, button_driver_internal_t, cb_data); 
  zephyr_interop_t *interop = parent->interop;


  parent->state = gpio_pin_get(parent->dev, parent->pin);

  svm_msg_t msg;
  msg.sender_id = parent->drv_id;
  msg.timestamp = sys_time_get_current_ticks();
  msg.data = parent->state;  // 1 or 0
  msg.msg_type = 0;

  if (interop->send_message(interop, msg) == -ENOMSG) {
    /* Message was not send due to queue being full.
       What do we do in this case?  */
  }
  irq_unlock(key);
}

/* Implementation of LL interface */
static uint32_t ll_button_control(struct ll_driver_s *this, uint8_t *data, uint32_t data_size) {
  return 0;
}

static uint32_t ll_button_data_available(struct ll_driver_s *this) {
  return 1;
}

static uint32_t ll_button_data_writeable(struct ll_driver_s *this) {
  return 0;
}

static uint32_t ll_button_read(struct ll_driver_s *this, uint8_t *data, uint32_t data_size) {

  ll_button_driver_t *b = (ll_button_driver_t*)this->driver_info;

  uint32_t r = 0;

  if (data_size == 4) {
    data[0] = b->internal.state;
    data[1] = b->internal.state >> 8;
    data[2] = b->internal.state >> 16;
    data[3] = b->internal.state >> 24;
    r = 4;
  }

  return r;
}

static uint32_t ll_button_write(struct ll_driver_s *this, uint8_t *data, uint32_t data_size) {
  return 0;
}

bool ll_button_init(ll_driver_t* lld, ll_button_driver_t *bdrv) {

  lld->driver_info = bdrv;

  /* TODO: Check that all fields of bdrv has been initialized */

  lld->is_synchronous = false;
  lld->ll_control_fun = ll_button_control;
  lld->ll_read_fun = ll_button_read;
  lld->ll_write_fun = ll_button_write;
  lld->ll_data_readable_fun = ll_button_data_available;
  lld->ll_data_writeable_fun = ll_button_data_writeable;

  return true; // TODO: FIXME
}
