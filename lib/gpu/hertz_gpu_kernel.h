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

#ifndef HERTZ_GPU_KERNEL
#define HERTZ_GPU_KERNEL

#include "cuPrintf.cu"
#include "hashmap.cu"
#define sqrtFiveOverSix 0.91287092917527685576161630466800355658790782499663875

__device__ void pair_interaction(
  //inputs
    double *xi, double *xj,           //position
    double *vi, double *vj,           //velocity
    double *omegai, double *omegaj,   //rotational velocity
    double radi, double radj,         //radius
    double rmassi, double rmassj,     //] mass
    double massi, double massj,       //]
    int typei, int typej,             //type
    double dt,                        //timestep

  //contact model parameters inputs
    int num_atom_types,
    double *Yeff,
    double *Geff,
    double *betaeff,
    double *coeffFrict,
    double nktv2p,

  //inouts
    double *shear,
    double *torque,
    double *force) {

  // del is the vector from j to i
  double delx = xi[0] - xj[0];
  double dely = xi[1] - xj[1];
  double delz = xi[2] - xj[2];

  double rsq = delx*delx + dely*dely + delz*delz;
  double radsum = radi + radj;
  if (rsq >= radsum*radsum) {
    //unset non-touching atoms
    shear[0] = 0.0;
    shear[1] = 0.0;
    shear[2] = 0.0;
  } else {
    //distance between centres of atoms i and j
    //or, magnitude of del vector
    double r = sqrt(rsq);
    double rinv = 1.0/r;
    double rsqinv = 1.0/rsq;

    // relative translational velocity
    double vr1 = vi[0] - vj[0];
    double vr2 = vi[1] - vj[1];
    double vr3 = vi[2] - vj[2];

    // normal component
    double vnnr = vr1*delx + vr2*dely + vr3*delz;
    double vn1 = delx*vnnr * rsqinv;
    double vn2 = dely*vnnr * rsqinv;
    double vn3 = delz*vnnr * rsqinv;

    // tangential component
    double vt1 = vr1 - vn1;
    double vt2 = vr2 - vn2;
    double vt3 = vr3 - vn3;

    // relative rotational velocity
    double wr1 = (radi*omegai[0] + radj*omegaj[0]) * rinv;
    double wr2 = (radi*omegai[1] + radj*omegaj[1]) * rinv;
    double wr3 = (radi*omegai[2] + radj*omegaj[2]) * rinv;

    // normal forces = Hookian contact + normal velocity damping
    double mi,mj;
    if (rmassi && rmassj) {
      mi=rmassi;
      mj=rmassj;
    } else if (massi && massj) {
      mi=massi;
      mj=massj;
    } else {
      //this should never fire
      return;
    }
    double meff = mi*mj/(mi+mj);
    //not-implemented: freeze_group_bit

    double deltan = radsum-r;

    //derive contact model parameters (inlined)
    //Yeff, Geff, betaeff, coeffFrict are lookup tables
    //TODO: put these in shared memory
    int typeij = typei + (typej * num_atom_types);
    double reff = radi * radj / (radi + radj);
    double sqrtval = sqrt(reff * deltan);
    double Sn = 2.    * Yeff[typeij] * sqrtval;
    double St = 8.    * Geff[typeij] * sqrtval;
    double kn = 4./3. * Yeff[typeij] * sqrtval;
    double kt = St;
    double gamman=-2.*sqrtFiveOverSix*betaeff[typeij]*sqrt(Sn*meff);
    double gammat=-2.*sqrtFiveOverSix*betaeff[typeij]*sqrt(St*meff);
    double xmu=coeffFrict[typeij];
    //not-implemented if (dampflag == 0) gammat = 0;
    kn /= nktv2p;
    kt /= nktv2p;

    double damp = gamman*vnnr*rsqinv;
	  double ccel = kn*(radsum-r)*rinv - damp;

    //not-implemented cohesionflag

    // relative velocities
    double vtr1 = vt1 - (delz*wr2-dely*wr3);
    double vtr2 = vt2 - (delx*wr3-delz*wr1);
    double vtr3 = vt3 - (dely*wr1-delx*wr2);

    // shear history effects
    shear[0] += vtr1 * dt;
    shear[1] += vtr2 * dt;
    shear[2] += vtr3 * dt;

    // rotate shear displacements
    double rsht = shear[0]*delx + shear[1]*dely + shear[2]*delz;
    rsht *= rsqinv;

    shear[0] -= rsht*delx;
    shear[1] -= rsht*dely;
    shear[2] -= rsht*delz;

    // tangential forces = shear + tangential velocity damping
    double fs1 = - (kt*shear[0] + gammat*vtr1);
    double fs2 = - (kt*shear[1] + gammat*vtr2);
    double fs3 = - (kt*shear[2] + gammat*vtr3);

    // rescale frictional displacements and forces if needed
    double fs = sqrt(fs1*fs1 + fs2*fs2 + fs3*fs3);
    double fn = xmu * fabs(ccel*r);
    double shrmag = 0;
    if (fs > fn) {
      shrmag = sqrt(shear[0]*shear[0] +
                    shear[1]*shear[1] +
                    shear[2]*shear[2]);
      if (shrmag != 0.0) {
        shear[0] = (fn/fs) * (shear[0] + gammat*vtr1/kt) - gammat*vtr1/kt;
        shear[1] = (fn/fs) * (shear[1] + gammat*vtr2/kt) - gammat*vtr2/kt;
        shear[2] = (fn/fs) * (shear[2] + gammat*vtr3/kt) - gammat*vtr3/kt;
        fs1 *= fn/fs;
        fs2 *= fn/fs;
        fs3 *= fn/fs;
      } else {
        fs1 = fs2 = fs3 = 0.0;
      }
    }

    double fx = delx*ccel + fs1;
    double fy = dely*ccel + fs2;
    double fz = delz*ccel + fs3;

    double tor1 = rinv * (dely*fs3 - delz*fs2);
    double tor2 = rinv * (delz*fs1 - delx*fs3);
    double tor3 = rinv * (delx*fs2 - dely*fs1);

    // this is what we've been working up to!
    force[0] += fx;
    force[1] += fy;
    force[2] += fz;

    torque[0] -= radi*tor1;
    torque[1] -= radi*tor2;
    torque[2] -= radi*tor3;
  }
}

/* Cell list version of hertz kernel */
template<bool eflag, bool vflag, int blockSize>
__global__ void kernel_hertz_cell(
			       float3 *cell_list, unsigned int *cell_idx,
			       int *cell_type, int *cell_atom,
			       const int inum,
			       const int ncellx, const int ncelly, const int ncellz,
             //passed in global memory
             double *v,
             double *omega,
             double *radius,
             double *rmass,
             struct hashmap *shearmap,  //] inouts
             double *torque,            //]
             double *f,                 //]
             //passed through value
             double dt,
             int num_atom_types,
             double *Yeff,
             double *Geff,
             double *betaeff,
             double *coeffFrict,
             double nktv2p)
{
  // calculate 3D block idx from 2d block
  int bx = blockIdx.x;
  int by = blockIdx.y % ncelly;
  int bz = blockIdx.y / ncelly;

  int tid = threadIdx.x;

  // compute cell idx from 3D block idx
  int cid = bx + INT_MUL(by, ncellx) + INT_MUL(bz, INT_MUL(ncellx,ncelly));

  __shared__ int typeSh[blockSize];
  __shared__ float posSh[blockSize*3];

  // compute neighbour cell bounds
  int nborz0 = max(bz-1,0), nborz1 = min(bz+1, ncellz-1),
      nbory0 = max(by-1,0), nbory1 = min(by+1, ncelly-1),
      nborx0 = max(bx-1,0), nborx1 = min(bx+1, ncellx-1);

  // for every atom in the cell (modulo current threadid)
  for (int ii = 0; ii < ceil((float)(cell_atom[cid])/blockSize); ii++) {
    int i = tid + ii*blockSize;
    unsigned int answer_pos = cell_idx[cid*blockSize+i];

    // load current cell atom position and type into sMem
    for (int j = tid; j < cell_atom[cid]; j += blockSize) {
      int pid = cid*blockSize + j;
      float3 pos = cell_list[pid];
      posSh[j            ] = pos.x;
      posSh[j+  blockSize] = pos.y;
      posSh[j+2*blockSize] = pos.z;
      typeSh[j]            = cell_type[pid];
    }
    __syncthreads();
    if (answer_pos < inum) {
      double xi[3]; double xj[3];
      double vi[3]; double vj[3];
      double omegai[3]; double omegaj[3];
      double radi; double radj;
      double rmassi; double rmassj;
      int typei; int typej;
      double *shear;
      double *torquei; double *force;

      //temporary
      double shear_dummy[3] = {0.0, 0.0, 0.0};
      shear = &shear_dummy[0];
      //temporary

      xi[0] = posSh[i            ];
      xi[1] = posSh[i+  blockSize];
      xi[2] = posSh[i+2*blockSize];
      typei = typeSh[i];
      //load from global memory (TODO: shift to shared)
      vi[0] = v[(answer_pos*3)];
      vi[1] = v[(answer_pos*3)+1];
      vi[2] = v[(answer_pos*3)+2];
      omegai[0] = omega[(answer_pos*3)];
      omegai[1] = omega[(answer_pos*3)+1];
      omegai[2] = omega[(answer_pos*3)+2];
      radi = radius[answer_pos];
      rmassi = rmass[answer_pos];
      force = &f[answer_pos*3];
      torquei = &torque[answer_pos*3];

      // compute force within cell first
      for (int j = 0; j < cell_atom[cid]; j++) {
	      if (j == i) continue;
        xj[0] = posSh[j            ];
        xj[1] = posSh[j+  blockSize];
        xj[2] = posSh[j+2*blockSize];
        typej = typeSh[j];

        int idxj = cell_idx[cid*blockSize+j]; //within same cell as i
        vj[0] = v[(idxj*3)];
        vj[1] = v[(idxj*3)+1];
        vj[2] = v[(idxj*3)+2];
        omegaj[0] = omega[(idxj*3)];
        omegaj[1] = omega[(idxj*3)+1];
        omegaj[2] = omega[(idxj*3)+2];
        radj = radius[idxj];
        rmassj = rmass[idxj];
        struct entry *lookup = cuda_retrieve_hashmap(&shearmap[answer_pos], idxj);
        if (lookup == NULL) { //on miss, so go onto next j
          continue;
        }

        //todo why doesn't the following work?
        //shear = &(lookup->shear);
        //instead, have to copy and copy-back
        shear[0] = lookup->shear[0];
        shear[1] = lookup->shear[1];
        shear[2] = lookup->shear[2];

        pair_interaction(
            xi, xj, vi, vj, omegai, omegaj,
            radi, radj, rmassi, rmassj, 0, 0, typei, typej,
            //passed through (constant)
            dt, num_atom_types, Yeff, Geff, betaeff, coeffFrict, nktv2p,
            shear, torquei, force);

        //todo
        lookup->shear[0] = shear[0];
        lookup->shear[1] = shear[1];
        lookup->shear[2] = shear[2];
      }
      __syncthreads();

      // compute force from neigboring cells
      for (int nborz = nborz0; nborz <= nborz1; nborz++) {
        for (int nbory = nbory0; nbory <= nbory1; nbory++) {
          for (int nborx = nborx0; nborx <= nborx1; nborx++) {
            if (nborz == bz && nbory == by && nborx == bx) continue;
	          int cid_nbor = nborx +
                           INT_MUL(nbory,ncellx) +
	                         INT_MUL(nborz,INT_MUL(ncellx,ncelly));

            // load neighbor cell position and type into smem
            for (int j = tid; j < cell_atom[cid_nbor]; j += blockSize) {
              int pid = INT_MUL(cid_nbor,blockSize) + j;
              float3 pos = cell_list[pid];
              posSh[j            ] = pos.x;
              posSh[j+  blockSize] = pos.y;
              posSh[j+2*blockSize] = pos.z;
              typeSh[j]           = cell_type[pid];
            }
            __syncthreads();
            if (answer_pos < inum) {
              for (int j = 0; j < cell_atom[cid_nbor]; j++) {
                xj[0] = posSh[j            ];
                xj[1] = posSh[j+  blockSize];
                xj[2] = posSh[j+2*blockSize];
                typej = typeSh[j];

                int idxj = cell_idx[cid_nbor*blockSize+j];
                vj[0] = v[(idxj*3)];
                vj[1] = v[(idxj*3)+1];
                vj[2] = v[(idxj*3)+2];
                omegaj[0] = omega[(idxj*3)];
                omegaj[1] = omega[(idxj*3)+1];
                omegaj[2] = omega[(idxj*3)+2];
                radj = radius[idxj];
                rmassj = rmass[idxj];
                struct entry *lookup = cuda_retrieve_hashmap(&shearmap[answer_pos], idxj);
                if (lookup == NULL) { //on miss, so go onto next j
                  continue;
                }

                shear[0] = lookup->shear[0];
                shear[1] = lookup->shear[1];
                shear[2] = lookup->shear[2];

                pair_interaction(
                    xi, xj, vi, vj, omegai, omegaj,
                    radi, radj, rmassi, rmassj, 0, 0, typei, typej,
                    //passed through (constant)
                    dt, num_atom_types, Yeff, Geff, betaeff, coeffFrict, nktv2p,
                    shear, torquei, force);

                lookup->shear[0] = shear[0];
                lookup->shear[1] = shear[1];
                lookup->shear[2] = shear[2];
              }
            }
          }
        }
      }
    }
  }
}

#endif
