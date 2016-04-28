/* CTBangBang is GPU and CPU CT reconstruction Software */
/* Copyright (C) 2015  John Hoffman */

/* This program is free software; you can redistribute it and/or */
/* modify it under the terms of the GNU General Public License */
/* as published by the Free Software Foundation; either version 2 */
/* of the License, or (at your option) any later version. */

/* This program is distributed in the hope that it will be useful, */
/* but WITHOUT ANY WARRANTY; without even the implied warranty of */
/* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the */
/* GNU General Public License for more details. */

/* You should have received a copy of the GNU General Public License */
/* along with this program; if not, write to the Free Software */
/* Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA. */

/* Questions and comments should be directed to */
/* jmhoffman@mednet.ucla.edu with "CTBANGBANG" in the subject line*/


#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <regex.h>
#include <cstdarg>
#include <unistd.h>
#include <sys/types.h>
#include <pwd.h>

#include <ctbb_macros.h>
#include <recon_structs.h>
#include <setup.h>
#include <preprocessing.h>
#include <rebin_filter.h>
#include <rebin_filter_cpu.h>
#include <backproject.h>
#include <backproject_cpu.h>
#include <finalize_image_stack.h>
#include <finalize_image_stack_cpu.h>

void log(int verbosity, const char *string, ...);
void split_path_file(char**p, char**f, char *pf);

void usage(){
    printf("\n");
    printf("usage: recon [options] input_prm_file\n\n");
    printf("    Options:\n");
    printf("          -v: verbose.\n");
    printf("          -t: test files will be written to desktop.\n");
    printf("    --no-gpu: run program exclusively on CPU. Will override --device=i option.\n");
    printf("  --device=i: run on GPU device number 'i'\n");
    printf("    --timing: Display timing information for each step of the recon process\n");
    printf(" --benchmark: Writes timing data to file used by benchmarking tool\n");
    printf("\n");
    printf("Copyright John Hoffman 2015\n\n");
    exit(0);
}


int main(int argc, char ** argv){

    struct recon_metadata mr;
    memset(&mr,0,sizeof(struct recon_metadata));

    // Parse any command line arguments
    if (argc<2)
	usage();
    
    regex_t regex_dev;
    regmatch_t regmatch_dev;
    if (regcomp(&regex_dev,"--device=*",0)!=0){
	printf("Regex didn't work properly\n");
	exit(1);
    }
    
    for (int i=1;i<(argc-1);i++){
	if (strcmp(argv[i],"-t")==0){
	    mr.flags.testing=1;
	}
	else if (strcmp(argv[i],"-v")==0){
	    mr.flags.verbose=1;
	}
	else if (strcmp(argv[i],"--no-gpu")==0){
	    mr.flags.no_gpu=1;
	}
	else if (regexec(&regex_dev,argv[i],1,&regmatch_dev,0)==0){
	    mr.flags.set_device=1;
	    sscanf(argv[i],"--device=%d",&mr.flags.device_number);
	}
	else if (strcmp(argv[i],"--timing")==0){
	    mr.flags.timing=1;
	}
	else if (strcmp(argv[i],"--benchmark")==0){
	    mr.flags.benchmark=1;
	}
	else{
	    usage();
	}
    }

    log(mr.flags.verbose,"\n-------------------------\n"
	"|      CTBangBang       |\n"
	"-------------------------\n\n");

    log(mr.flags.verbose,"CHECKING INPUT PARAMETERS AND CONFIGURING RECONSTRUCTION\n"
	"\n");
    
    /* --- Get working directory and User's home directory --- */
    struct passwd *pw=getpwuid(getuid());
    
    const char * homedir=pw->pw_dir;
    strcpy(mr.homedir,homedir);
    char full_exe_path[4096]={0};
    char * exe_path=(char*)calloc(4096,sizeof(char));
    char * exe_name=(char*)calloc(255,sizeof(char));
    readlink("/proc/self/exe",full_exe_path,4096);
    split_path_file(&exe_path,&exe_name,full_exe_path);
    strcpy(mr.install_dir,exe_path);
    mr.install_dir[strlen(mr.install_dir)-1]=0;
    
    /* --- Step 0: configure our processor (CPU or GPU) */
    // We want to send to the GPU furthest back in the list which is
    // unlikely to have a display connected.  We also check for the
    // user passing a specific device number via the command line

    int device_count=0;
    cudaGetDeviceCount(&device_count);
    if (device_count==0){
	mr.flags.no_gpu=1;
    }

    // Configure the GPU/CPU selection
    if (mr.flags.no_gpu==0){
	int device;
	if (mr.flags.set_device==1){
	    log(mr.flags.verbose,"CUDA device %d requested.\n",mr.flags.device_number);
	    log(mr.flags.verbose,"Attempting to set device... ");
	    cudaSetDevice(mr.flags.device_number);
	    cudaGetDevice(&device);
	    if (device!=mr.flags.device_number){
		printf("There was a problem setting device.\n");
	    }
	    else{
		log(mr.flags.verbose,"success!\n");
	    }
	}
	else{
	    cudaSetDevice(device_count-1);
	    cudaGetDevice(&device);
	}	
	log(mr.flags.verbose,"Working on GPU %i \n",device);
	cudaDeviceReset();
    }
    else{
	log(mr.flags.verbose,"Working on CPU\n");
    }

    // --timing cuda events
    TIMER_INIT();

    /* --- Step 1-3 handled by functions in setup.cu --- */
    // Step 1: Parse input file
    log(mr.flags.verbose,"Reading PRM file...\n");
    mr.rp=configure_recon_params(argv[argc-1]);

    /* --- Check for defined output directory, set to desktop if empty --- */
    strcpy(mr.output_dir,mr.rp.output_dir);
    if (strcmp(mr.output_dir,"")==0){
	char fullpath[4096+255];
	strcpy(fullpath,mr.homedir);
	strcat(fullpath,"/Desktop/");
	strcpy(mr.output_dir,fullpath);
    }
    
    // Step 2a: Setup scanner geometry
    log(mr.flags.verbose,"Configuring scanner geometry...\n");
    mr.cg=configure_ct_geom(&mr);
    
    // Step 2b: Configure all remaining information
    log(mr.flags.verbose,"Configuring final reconstruction parameters...\n");
    configure_reconstruction(&mr);

    log(mr.flags.verbose,"Allowed recon range: %.2f to %.2f\n",mr.ri.allowed_begin,mr.ri.allowed_end);
    log(mr.flags.verbose,"\nSTARTING RECONSTRUCTION\n\n");
    
    for (int i=0;i<mr.ri.n_blocks;i++){
	
	update_block_info(&mr);
	
	log(mr.flags.verbose,"----------------------------\n"
	    "Working on block %d of %d \n",i+1,mr.ri.n_blocks);
	
	// Step 3: Extract raw data from file into memory
	log(mr.flags.verbose,"Reading raw data from file...\n");
	extract_projections(&mr);

	/* --- Step 3.5: Adaptive filtration handled by preprocessing.cu ---*/
	// Step 3.5: Adaptive filtration of raw data to reduce streak artifacts
	log(mr.flags.verbose,"Running adaptive filtering...\n");

	TIME_EXEC(adaptive_filter_kk(&mr),mr.flags.timing,"adaptive_filtration");

	/* --- Step 4 handled by functions in rebin_filter.cu --- */
	// Step 4: Rebin and filter
	log(mr.flags.verbose,"Rebinning and filtering data...\n");

	if (mr.flags.no_gpu==1){
	    TIME_EXEC(rebin_filter_cpu(&mr),mr.flags.timing,"rebinning and filtering");
	}
	else{
	    TIME_EXEC(rebin_filter(&mr),mr.flags.timing,"rebinning and filtering");
	}

	/* --- Step 5 handled by functions in backproject.cu ---*/
	// Step 5: Backproject
	log(mr.flags.verbose,"Backprojecting...\n");

	if (mr.flags.no_gpu==1){
	    TIME_EXEC(backproject_cpu(&mr),mr.flags.timing,"backprojection");
	}
	else{
	    TIME_EXEC(backproject(&mr),mr.flags.timing,"backprojections");;
	}
    }

    // Step 6: Reorder and thicken slices as needed
    log(mr.flags.verbose,"----------------------------\n");
    log(mr.flags.verbose,"Finalizing image stack...\n");
    
    if (mr.flags.no_gpu==1){
	TIME_EXEC(finalize_image_stack_cpu(&mr),mr.flags.timing,"reordering and thickening slices");
    }
    else{
	TIME_EXEC(finalize_image_stack(&mr),mr.flags.timing,"reordering and thickening slices");
    }
    
    // Step 7: Save image data to disk (found in setup.cu)
    log(mr.flags.verbose,"----------------------------\n\n");
    log(mr.flags.verbose,"Writing image data to %s%s.img\n",mr.output_dir,mr.rp.raw_data_file);
    finish_and_cleanup(&mr);

    log(mr.flags.verbose,"Done.\n");

    cudaDeviceReset();
    return 0;
   
}

void log(int verbosity, const char *string,...){
    va_list args;
    va_start(args,string);

    if (verbosity){
	vprintf(string,args);
	va_end(args);
    } 
}

void split_path_file(char**p, char**f, char *pf) {
    char *slash = pf, *next;
    while ((next = strpbrk(slash + 1, "\\/"))) slash = next;
    if (pf != slash) slash++;
    *p = strndup(pf, slash - pf);
    *f = strdup(slash);
}
