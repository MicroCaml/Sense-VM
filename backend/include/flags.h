/**********************************************************************************/
/* MIT License									  */
/* 										  */
/* Copyright (c) 2020 Joel Svensson             				  */
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

#ifndef __FLAGS_H_
#define __FLAGS_H_

typedef uint32_t heap_flags_t;
typedef uint16_t value_flags_t;

/* Bit masks for flags of a memory cell */
/* Tweak these later to make more sense */ 
#define     HEAP_GC_MARK_BIT_MASK     0x80000000
#define     HEAP_GC_FLAG_BIT_MASK     0x40000000
#define     HEAP_PTR_MASK_1           0x08000000 /* is data[1] a ptr ? */
#define     HEAP_PTR_MASK_0           0x00000800 /* is data[2] a ptr ? */

#define     HEAP_FLAGS_DEFAULT        0x00000000



#define     VALUE_PTR_MASK            0x0800



#endif
