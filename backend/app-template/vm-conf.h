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

#ifndef __VM_CONF_H_
#define __VM_CONF_H_

/***********************************************/
/* Sense-VM Application Configuration Settings */
/***********************************************/



/********************************************/
/* Virtual Machine Container (VMC) settings */
/********************************************/

#define VMC_NUM_CONTAINERS 1 // Defines the number of Virtual Machine Containers to run


/*********/
/* VMC 1 */
/*********/
#define VMC_CONTAINER_1_HEAP_SIZE_BYTES       8192
#define VMC_CONTAINER_1_BYTECODE_FILE         "test.X"
#define VMC_CONTAINER_1_STACK_SIZE_BYTES      1024
#define VMC_CONTAINER_1_ARRAY_MEM_SIZE_BYTES  4096



/*********/
/* VMC 2 */
/*********/
//#define VMC_CONTAINER_2_HEAP_SIZE_BYTES      8192
//#define VMC_CONTAINER_2_BYTECODE_FILE        "tests/test.X"
//#define VMC_CONTAINER_2_STACK_SIZE_BYTES     1024
//#define VMC_CONTAINER_2_ARRAY_MEM_SIZE_BYTES  4096



#endif
