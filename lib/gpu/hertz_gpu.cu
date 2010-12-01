/* ----------------------------------------------------------------------
   LAMMPS - Large-scale Atomic/Molecular Massively Parallel Simulator
   http://lammps.sandia.gov, Sandia National Laboratories
   Steve Plimpton, sjplimp@sandia.gov

   Copyright (2003) Sandia Corporation.  Under the terms of Contract
   DE-AC04-94AL85000 with Sandia Corporation, the U.S. Government retains
   certain rights in this software.  This software is distributed under 
   the GNU General Public License.

   See the README file in the top-level LAMMPS directory.
------------------------------------------------------------------------- */

/* ----------------------------------------------------------------------
   Contributing authors: Mike Brown (SNL), wmbrown@sandia.gov
                         Peng Wang (Nvidia), penwang@nvidia.com
                         Paul Crozier (SNL), pscrozi@sandia.gov
------------------------------------------------------------------------- */

#include <iostream>
#include <cassert>
#include "nvc_macros.h"
#include "nvc_timer.h"
#include "nvc_device.h"
#include "pair_gpu_texture.h"
#include "pair_gpu_cell.h"
#include "lj_gpu_memory.cu"
#include "hertz_gpu_kernel.h"

#include "cuPrintf.cu"
#include "hashmap.cu"

// ---------------------------------------------------------------------------
// Return string with GPU info
// ---------------------------------------------------------------------------
EXTERN void hertz_gpu_name(const int id, const int max_nbors, char * name) {
  strcpy(name,"hertz");
}

// ---------------------------------------------------------------------------
// Allocate memory on host and device and copy constants to device
// ---------------------------------------------------------------------------
EXTERN bool hertz_gpu_init(
  double *boxlo, double *boxhi, 
	double cell_size, double skin)
{

  ncellx = ceil(((boxhi[0] - boxlo[0]) + 2.0*cell_size) / cell_size);
  ncelly = ceil(((boxhi[1] - boxlo[1]) + 2.0*cell_size) / cell_size);
  ncellz = ceil(((boxhi[2] - boxlo[2]) + 2.0*cell_size) / cell_size);

  printf("> hertz_gpu_init\n");
  printf("> cell_size = %f\n", cell_size);
  printf("> boxhi = {%f, %f, %f}; boxlo = {%f, %f, %f}\n", 
    boxhi[0], boxhi[1], boxhi[2],
    boxlo[0], boxlo[1], boxlo[2]);
  printf("> ncellx = %d; ncelly = %d; ncellz = %d;\n",
    ncellx, ncelly, ncellz);
   
  init_cell_list_const(cell_size, skin, boxlo, boxhi);

  return true;
}

// ---------------------------------------------------------------------------
// Clear memory on host and device
// ---------------------------------------------------------------------------
EXTERN void hertz_gpu_clear() {
}

EXTERN struct hashmap **create_shearmap(
  //number of atoms (ranged over by ii)
  int inum, /*list->inum*/
  //id of atom ii (ranged over by i)
  int *ilist, /*list->ilist*/
  //numneigh[i] is the number of neighbor atoms to atom i (ranged over by jj)
  int *numneigh, /*list->numneigh*/
  //firstneigh[i][jj] is the id of atom jj (ranged over by j)
  int **firstneigh, /*list->firstneigh*/
  //firsttouch[i][jj] = 1, if i and j are in contact
  //                    0, otherwise
  int **firsttouch, /*listgranhistory->firstneigh*/
  //firstshear[i][3*jj] is the shear vector between atoms i and j
  double **firstshear /*listgranhistory->firstdouble*/) {

  //shearmap[i] is a hashmap for atoms in contact with atom i
  struct hashmap **shearmap;
  shearmap = (struct hashmap **)malloc(sizeof(struct hashmap) * inum);

  for (int ii=0; ii<inum; ii++) {
    int i = ilist[ii];
    int jnum = numneigh[i];
    assert(jnum < 32);

    struct hashmap *hm = create_hashmap(32);
    for (int jj = 0; jj<jnum; jj++) {
      int j = firstneigh[i][jj];

      //TODO: necessary to check firsttouch[i][jj] == 1?
      double *shear = &firstshear[i][3*jj];
      insert_hashmap(hm, j, shear);
    }
    shearmap[i] = hm;
  }

  //paranoid
  for (int ii=0; ii<inum; ii++) {
    int i = ilist[ii];
    int jnum = numneigh[i];

    struct hashmap *hm = create_hashmap(32);
    for (int jj = 0; jj<jnum; jj++) {
      int j = firstneigh[i][jj];
      double *shear = &firstshear[i][3*jj];

      struct entry *result = retrieve_hashmap(shearmap[i], j);
      assert(result);
      assert(result->shear[0] == shear[0]);
      assert(result->shear[1] == shear[1]);
      assert(result->shear[2] == shear[2]);
    }
  }

  return shearmap;
}

EXTERN void compare_shearmap(
  FILE *ofile,
  struct hashmap **shearmap,
  int inum,
  int *ilist,
  int *numneigh,
  int **firstneigh,
  int **firsttouch,
  double **firstshear) {

  struct entry *result = retrieve_hashmap(shearmap[107], 108);
  for (int ii=0; ii<inum; ii++) {
    int i = ilist[ii];
    int jnum = numneigh[i];

    for (int jj = 0; jj<jnum; jj++) {
      int j = firstneigh[i][jj];

      struct entry *result = retrieve_hashmap(shearmap[i], j);
      if (result == NULL) {
        fprintf(ofile, "shear[%d][%d] mismatch!\n", i,j);
      }
      double *shear = &firstshear[i][3*jj];
      for (int k=0; k<3; k++) {
        fprintf(ofile, "shear[%d][%d][%d], %.16f, %.16f\n", i,j,k,shear[k], result->shear[k]);
      }
    }
  }
}

EXTERN void update_from_shearmap(
  struct hashmap **shearmap,
  int inum,
  int *ilist,
  int *numneigh,
  int **firstneigh,
  int **firsttouch,
  double **firstshear) {

  for (int ii=0; ii<inum; ii++) {
    int i = ilist[ii];
    int jnum = numneigh[i];

    for (int jj = 0; jj<jnum; jj++) {
      int j = firstneigh[i][jj];

      struct entry *result = retrieve_hashmap(shearmap[i], j);
      double *shear = &firstshear[i][3*jj];
      shear[0] = result->shear[0];
      shear[1] = result->shear[1];
      shear[2] = result->shear[2];
      //TODO: necessary to uncheck firsttouch[i][jj]?
    }
  }
}

struct hashmap *c_to_device_shearmap(struct hashmap **shearmap, int inum) { 
  struct hashmap *d_shearmap;
  ASSERT_NO_CUDA_ERROR(
    cudaMalloc((void **)&d_shearmap, sizeof(struct hashmap) * inum));

  for (int i=0; i<inum; i++) {
    struct hashmap *d_hm = c_to_device_hashmap(shearmap[i]);
    ASSERT_NO_CUDA_ERROR(cudaMemcpy(&d_shearmap[i], d_hm, sizeof(struct hashmap), cudaMemcpyDeviceToDevice));
  }
  return d_shearmap;
}

struct hashmap **device_to_c_shearmap(struct hashmap *d_shearmap, int inum) {
  struct hashmap **shearmap = 
    (struct hashmap **)malloc(sizeof(struct hashmap) * inum);
  for (int i=0; i<inum; i++) {
    shearmap[i] = device_to_c_hashmap(&d_shearmap[i]);
  }
  return shearmap;
}

EXTERN double hertz_gpu_cell(
  const bool eflag, const bool vflag,
  const int inum, const int nall, const int ago,

  //inputs
  double **host_x, double **host_v, double **host_omega,
  double *host_radius, double *host_rmass,
  int *host_type,
  double dt,

  //stiffness parameters
  int num_atom_types,
  double **host_Yeff,
  double **host_Geff,
  double **host_betaeff,
  double **host_coeffFrict,
  double nktv2p,

  //inouts 
  struct hashmap***host_shear, double **host_torque, double **host_force)
{
  static int blockSize = BLOCK_1D;
  static int ncell = ncellx*ncelly*ncellz;

#ifdef VERBOSE
  printf("> inum = %d\n", inum);
  printf("> nall = %d\n", nall);
#endif
  // -----------------------------------------------------------
  // Device variables
  // -----------------------------------------------------------
  const int SIZE_1D = (nall * sizeof(double));
  const int SIZE_2D = (3 * SIZE_1D);
  static bool first_call = true;
  if (first_call) {
    first_call = false;

    init_cell_list(cell_list_gpu, nall, ncell, blockSize);

    //malloc device data
    cudaMalloc((void**)&d_v, SIZE_2D);
    cudaMalloc((void**)&d_omega, SIZE_2D);
    cudaMalloc((void**)&d_shear, SIZE_2D);
    cudaMalloc((void**)&d_torque, SIZE_2D);
    cudaMalloc((void**)&d_f, SIZE_2D);
    //shear done later

    cudaMalloc((void**)&d_radius, SIZE_1D);
    cudaMalloc((void**)&d_rmass, SIZE_1D);

    const int PARAM_SIZE = num_atom_types * num_atom_types * sizeof(double);
    cudaMalloc((void**)&d_Yeff, PARAM_SIZE);
    cudaMalloc((void**)&d_Geff, PARAM_SIZE);
    cudaMalloc((void**)&d_betaeff, PARAM_SIZE);
    cudaMalloc((void**)&d_coeffFrict, PARAM_SIZE);

    //flatten stiffness lookup tables
    double *h_Yeff = (double *)malloc(PARAM_SIZE);
    double *h_Geff = (double *)malloc(PARAM_SIZE);
    double *h_betaeff = (double *)malloc(PARAM_SIZE);
    double *h_coeffFrict = (double *)malloc(PARAM_SIZE);
    for (int i=0; i<num_atom_types; i++) {
      for (int j=0; j<num_atom_types; j++) {
        h_Yeff[i + (j*num_atom_types)] = host_Yeff[i][j];
        h_Geff[i + (j*num_atom_types)] = host_Geff[i][j];
        h_betaeff[i + (j*num_atom_types)] = host_betaeff[i][j];
        h_coeffFrict[i + (j*num_atom_types)] = host_coeffFrict[i][j];
      }
    }
    cudaMemcpy(d_Yeff, h_Yeff, PARAM_SIZE, cudaMemcpyHostToDevice);
    cudaMemcpy(d_Geff, h_Geff, PARAM_SIZE, cudaMemcpyHostToDevice);
    cudaMemcpy(d_betaeff, h_betaeff, PARAM_SIZE, cudaMemcpyHostToDevice);
    cudaMemcpy(d_coeffFrict, h_coeffFrict, PARAM_SIZE, cudaMemcpyHostToDevice);
  }

  //flatten 2d atom data
  double *h_v = (double *)malloc(SIZE_2D);
  double *h_omega = (double *)malloc(SIZE_2D);
  double *h_torque = (double *)malloc(SIZE_2D);
  double *h_f = (double *)malloc(SIZE_2D);
  for (int i=0; i< nall; i++) {
    for (int j=0; j<3; j++) {
      h_v[(i*3)+j] = host_v[i][j];
      h_omega[(i*3)+j] = host_omega[i][j];
      h_torque[(i*3)+j] = host_torque[i][j];
      h_f[(i*3)+j] = host_force[i][j];
    }
  }
  cudaMemcpy(d_v, h_v, SIZE_2D, cudaMemcpyHostToDevice);
  cudaMemcpy(d_omega, h_omega, SIZE_2D, cudaMemcpyHostToDevice);
  cudaMemcpy(d_torque, h_torque, SIZE_2D, cudaMemcpyHostToDevice);
  cudaMemcpy(d_f, h_f, SIZE_2D, cudaMemcpyHostToDevice);

  //just copy across 1d atom data
  cudaMemcpy(d_radius, host_radius, SIZE_1D, cudaMemcpyHostToDevice);
  cudaMemcpy(d_rmass, host_rmass, SIZE_1D, cudaMemcpyHostToDevice);

  build_cell_list(host_x[0], host_type, cell_list_gpu, 
	  ncell, ncellx, ncelly, ncellz, blockSize, inum, nall, ago);

  struct hashmap *d_shearmap = c_to_device_shearmap(*host_shear, inum);

  cudaError_t err = cudaGetLastError();
  if (err != cudaSuccess) {
    printf("Pre-kernel error: %s.\n", cudaGetErrorString(err));
    exit(1);
  }

  const int BX=blockSize;
  dim3 GX(ncellx, ncelly*ncellz);

#ifdef VERBOSE
  printf("kernel<<<BX=%d, GX=(%d,%d)>>>\n", BX, ncellx, ncelly*ncellz);
  cudaPrintfInit(0x1<<30);
#endif

  kernel_hertz_cell<true,true,64><<<GX,BX>>>(
    cell_list_gpu.pos,
    cell_list_gpu.idx,
    cell_list_gpu.type,
    cell_list_gpu.natom,
    inum, ncellx, ncelly, ncellz,
    d_v, d_omega, d_radius, d_rmass, d_shearmap, d_torque, d_f,
    dt, num_atom_types,
    d_Yeff, d_Geff, d_betaeff, d_coeffFrict, nktv2p
  );

#ifdef VERBOSE
  cudaPrintfDisplay(stdout, true);
  //FILE *ofile = fopen("kernel_list.txt", "w");
  //cudaPrintfDisplay(ofile, true);
  cudaPrintfEnd();
#endif

  cudaThreadSynchronize();
  err = cudaGetLastError();
  if (err != cudaSuccess) {
    printf("Post-kernel error: %s.\n", cudaGetErrorString(err));
    exit(1);
  }

  //copy back force calculations (shear, torque, force)
  *host_shear = device_to_c_shearmap(d_shearmap ,inum);
  cudaMemcpy(h_torque, d_torque, SIZE_2D, cudaMemcpyDeviceToHost);
  cudaMemcpy(h_f, d_f, SIZE_2D, cudaMemcpyDeviceToHost);
  for (int i=0; i<nall; i++) {
    host_torque[i][0] = h_torque[(i*3)];
    host_torque[i][1] = h_torque[(i*3)+1];
    host_torque[i][2] = h_torque[(i*3)+2];

    host_force[i][0] = h_f[(i*3)];
    host_force[i][1] = h_f[(i*3)+1];
    host_force[i][2] = h_f[(i*3)+2];
  }

  return 0.0;
}

EXTERN void hertz_gpu_time() {
}

EXTERN int hertz_gpu_num_devices() {
  return 0;
}

EXTERN double hertz_gpu_bytes() {
  return 0.0;
}
