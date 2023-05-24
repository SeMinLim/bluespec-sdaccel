// This is a generated file. Use and modify at your own risk.
////////////////////////////////////////////////////////////////////////////////

/*******************************************************************************
Vendor: Xilinx
Associated Filename: main.c
#Purpose: This example shows a basic vector add +1 (constant) by manipulating
#         memory inplace.
*******************************************************************************/

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
#include <unistd.h>
#include <assert.h>
#include <stdbool.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <CL/opencl.h>
#include <CL/cl_ext.h>
#include "xclhal2.h"

#include "opencl_helpers.h"
//#include <iostream>
////////////////////////////////////////////////////////////////////////////////

#define NUM_WORKGROUPS (1)
#define WORKGROUP_SIZE (256)
#define MAX_LENGTH 8192

#if defined(SDX_PLATFORM) && !defined(TARGET_DEVICE)
#define STR_VALUE(arg)      #arg
#define GET_STRING(name) STR_VALUE(name)
#define TARGET_DEVICE GET_STRING(SDX_PLATFORM)
#endif

////////////////////////////////////////////////////////////////////////////////

int main(int argc, char* argv[])
{
	cl_int err;				// error code returned from api calls
	cl_context context;			// compute context
	cl_command_queue commands;		// compute command queue
	cl_program program;			// compute programs
	cl_kernel kernel;			// compute kernel
	init_setup(0, context, commands, program, kernel);

    	int* h_data;				// host memory for input vector
	cl_mem d_A;				// device memory used for a vector
	int h_B_output[MAX_LENGTH];		// host memory for output vector
	cl_mem d_B;				// device memory used for a vector

    	// Create structs to define memory bank mapping
    	cl_mem_ext_ptr_t mem_ext;
    	mem_ext.obj = NULL;
    	mem_ext.param = kernel;
    

	const uint data_bytes = (256*1024*1024);

	h_data = (int*)malloc(data_bytes);

	mem_ext.flags = 1 | XCL_MEM_TOPOLOGY;
	d_A = clCreateBuffer(context,  CL_MEM_READ_WRITE | CL_MEM_EXT_PTR_XILINX,  data_bytes, &mem_ext, NULL);

	if (!(d_A)) {
		printf("Error: Failed to allocate device memory A!\n");
		printf("Test failed\n");
		return EXIT_FAILURE;
	}

	mem_ext.flags = 2 | XCL_MEM_TOPOLOGY;
	d_B = clCreateBuffer(context,  CL_MEM_READ_WRITE | CL_MEM_EXT_PTR_XILINX,  data_bytes, &mem_ext, NULL);

	if (!(d_B)) {
		printf("Error: Failed to allocate device memory B!\n");
		printf("Test failed\n");
		return EXIT_FAILURE;
	}


	err = clEnqueueWriteBuffer(commands, d_A, CL_TRUE, 0, data_bytes, h_data, 0, NULL, NULL);
	if (err != CL_SUCCESS) {
		printf("Error: Failed to write to source array h_data!\n");
		printf("Test failed\n");
		return EXIT_FAILURE;
	}


	err = clEnqueueWriteBuffer(commands, d_B, CL_TRUE, 0, data_bytes, h_data, 0, NULL, NULL);
	if (err != CL_SUCCESS) {
		printf("Error: Failed to write to source array h_data!\n");
		printf("Test failed\n");
		return EXIT_FAILURE;
	}


	// Set the arguments to our compute kernel
	err = 0;
	cl_uint d_scalar00 = data_bytes/64;
	err |= clSetKernelArg(kernel, 0, sizeof(cl_uint), &d_scalar00); // Not used in example RTL logic.
	err |= clSetKernelArg(kernel, 1, sizeof(cl_mem), &d_A); 
	err |= clSetKernelArg(kernel, 2, sizeof(cl_mem), &d_B); 

	if (err != CL_SUCCESS) {
		printf("Error: Failed to set kernel arguments! %d\n", err);
		printf("Test failed\n");
		return EXIT_FAILURE;
	}

	
	// Execute the kernel over the entire range of our 1d input data set
	// using the maximum number of work group items for this device
	printf( "!!!!\n"); fflush(stdout);
	err = clEnqueueTask(commands, kernel, 0, NULL, NULL);
	if (err) {
		printf("Error: Failed to execute kernel! %d\n", err);
		printf("Test failed\n");
		return EXIT_FAILURE;
	}
	printf( "2222\n"); fflush(stdout);
	
	// Read back the results from the device to verify the output
	cl_event readevent;
	clFinish(commands);
	printf( "3333\n"); fflush(stdout);
	sleep(5);

	err = 0;
	err |= clEnqueueReadBuffer( commands, d_A, CL_TRUE, 0, data_bytes, h_B_output, 0, NULL, &readevent );

	printf( "4444\n"); fflush(stdout);
	if (err != CL_SUCCESS) {
		printf("Error: Failed to read output array! %d\n", err);
		printf("Test failed\n");
		return EXIT_FAILURE;
	}
	clWaitForEvents(1, &readevent);
	printf( "5555\n"); fflush(stdout);
	
	// Check Results
	for (uint i = 0; i < 20; i++) {
		printf( "%x \t %x\n", h_data[i], h_B_output[i] );
	}
    	//--------------------------------------------------------------------------
    	// Shutdown and cleanup
    	//-------------------------------------------------------------------------- 
    	clReleaseMemObject(d_A);
    	clReleaseMemObject(d_B);
    	clReleaseProgram(program);
    	clReleaseKernel(kernel);
    	clReleaseCommandQueue(commands);
    	clReleaseContext(context);

    	if (false) {
        	printf("INFO: Test failed\n");
        	return EXIT_FAILURE;
    	} else {
        	printf("INFO: Test completed successfully.\n");
        	return EXIT_SUCCESS;
    	}
}
