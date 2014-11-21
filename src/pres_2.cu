/*
 * MicroHH
 * Copyright (c) 2011-2014 Chiel van Heerwaarden
 * Copyright (c) 2011-2014 Thijs Heus
 * Copyright (c)      2014 Bart van Stratum
 *
 * This file is part of MicroHH
 *
 * MicroHH is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.

 * MicroHH is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.

 * You should have received a copy of the GNU General Public License
 * along with MicroHH.  If not, see <http://www.gnu.org/licenses/>.
 */

#include <cstdio>
#include <cmath>
#include <algorithm>
#include <fftw3.h>
#include <cufft.h>
#include "master.h"
#include "grid.h"
#include "fields.h"
#include "pres_2.h"
#include "defines.h"
#include "model.h"
#include "tools.h"
#include "constants.h"

const int TILE_DIM = 16;

namespace Pres2_g
{
  inline void cudaCheckFFTPlan(cufftResult err)
  {
    if (CUFFT_SUCCESS != err)
    {
      printf("cufftPlanMany() error\n");
      throw 1;
    }
  }

  __global__ void transpose(double *fieldOut, const double *fieldIn, const int itot, const int jtot, const int ktot)
  {
    __shared__ double tile[TILE_DIM][TILE_DIM+1];
    
    int i,j,k,ijk;
   
    // Index in fieldIn 
    i = blockIdx.x * TILE_DIM + threadIdx.x;
    j = blockIdx.y * TILE_DIM + threadIdx.y;
    k = blockIdx.z;
    ijk = i + j*itot + k*itot*jtot;
  
    // Read to shared memory
    if(i < itot && j < jtot)
      tile[threadIdx.y][threadIdx.x] = fieldIn[ijk];
   
    __syncthreads();
    
    // Transposed index
    i = blockIdx.y * TILE_DIM + threadIdx.x;
    j = blockIdx.x * TILE_DIM + threadIdx.y;
    ijk = i + j*jtot + k*itot*jtot;
   
    if(i < jtot && j < itot) 
      fieldOut[ijk] = tile[threadIdx.x][threadIdx.y];
  }

  __global__ void presin(double * __restrict__ p,
                         double * __restrict__ u ,  double * __restrict__ v ,     double * __restrict__ w ,
                         double * __restrict__ ut,  double * __restrict__ vt,     double * __restrict__ wt,
                         double * __restrict__ dzi, double * __restrict__ rhoref, double * __restrict__ rhorefh,
                         double dxi, double dyi, double dti,
                         const int jj, const int kk,
                         const int jjp, const int kkp,
                         const int imax, const int jmax, const int kmax,
                         const int igc, const int jgc, const int kgc)
  {
    const int ii = 1;
    const int i = blockIdx.x*blockDim.x + threadIdx.x;
    const int j = blockIdx.y*blockDim.y + threadIdx.y;
    const int k = blockIdx.z;

    if(i < imax && j < jmax && k < kmax)
    {
      const int ijkp = i + j*jjp + k*kkp;
      const int ijk  = i+igc + (j+jgc)*jj + (k+kgc)*kk;

      p[ijkp] = rhoref [k+kgc]   * ( (ut[ijk+ii] + u[ijk+ii] * dti) - (ut[ijk] + u[ijk] * dti) ) * dxi
              + rhoref [k+kgc]   * ( (vt[ijk+jj] + v[ijk+jj] * dti) - (vt[ijk] + v[ijk] * dti) ) * dyi
            + ( rhorefh[k+kgc+1] * (  wt[ijk+kk] + w[ijk+kk] * dti)
              - rhorefh[k+kgc  ] * (  wt[ijk   ] + w[ijk   ] * dti) ) * dzi[k+kgc];
    }
  }

  __global__ void presout(double * __restrict__ ut, double * __restrict__ vt, double * __restrict__ wt,
                          double * __restrict__ p,
                          double * __restrict__ dzhi, const double dxi, const double dyi,
                          const int jj, const int kk,
                          const int istart, const int jstart, const int kstart,
                          const int iend, const int jend, const int kend)
  {
    const int i = blockIdx.x*blockDim.x + threadIdx.x + istart;
    const int j = blockIdx.y*blockDim.y + threadIdx.y + jstart;
    const int k = blockIdx.z + kstart;

    const int ii = 1;

    if(i < iend && j < jend && k < kend)
    {
      int ijk = i + j*jj + k*kk;
      ut[ijk] -= (p[ijk] - p[ijk-ii]) * dxi;
      vt[ijk] -= (p[ijk] - p[ijk-jj]) * dyi;
      wt[ijk] -= (p[ijk] - p[ijk-kk]) * dzhi[k];
    }
  }

  __global__ void solveout(double * __restrict__ p, double * __restrict__ work3d,
                           const int jj, const int kk,
                           const int jjp, const int kkp,
                           const int istart, const int jstart, const int kstart,
                           const int imax, const int jmax, const int kmax)
  {
    const int i = blockIdx.x*blockDim.x + threadIdx.x;
    const int j = blockIdx.y*blockDim.y + threadIdx.y;
    const int k = blockIdx.z;

    if(i < imax && j < jmax && k < kmax)
    {
      const int ijk  = i + j*jj + k*kk;
      const int ijkp = i+istart + (j+jstart)*jjp + (k+kstart)*kkp;

      p[ijkp] = work3d[ijk];

      if(k == 0)
        p[ijkp-kkp] = p[ijkp];
    }
  }

  __global__ void solvein(double * __restrict__ p,
                          double * __restrict__ work3d, double * __restrict__ b,
                          double * __restrict__ a, double * __restrict__ c,
                          double * __restrict__ dz, double * __restrict__ rhoref,
                          double * __restrict__ bmati, double * __restrict__ bmatj,
                          const int jj, const int kk,
                          const int imax, const int jmax, const int kmax,
                          const int kstart)
  {
    int i = blockIdx.x*blockDim.x + threadIdx.x;
    int j = blockIdx.y*blockDim.y + threadIdx.y;
    int k = blockIdx.z;

    if(i < imax && j < jmax && k < kmax)
    {
      int ijk = i + j*jj + k*kk;

      // CvH this needs to be taken into account in case of an MPI run
      // iindex = mpi->mpicoordy * iblock + i;
      // jindex = mpi->mpicoordx * jblock + j;
      // b[ijk] = dz[k+kgc]*dz[k+kgc] * (bmati[iindex]+bmatj[jindex]) - (a[k]+c[k]);
      //  if(iindex == 0 && jindex == 0)

      b[ijk] = dz[k+kstart]*dz[k+kstart] * rhoref[k+kstart]*(bmati[i]+bmatj[j]) - (a[k]+c[k]);
      p[ijk] = dz[k+kstart]*dz[k+kstart] * p[ijk];

      if(k == 0)
      {
        // substitute BC's
        // ijk = i + j*jj;
        b[ijk] += a[0];
      }
      else if(k == kmax-1)
      {
        // for wave number 0, which contains average, set pressure at top to zero
        if(i == 0 && j == 0)
          b[ijk] -= c[k];
        // set dp/dz at top to zero
        else
          b[ijk] += c[k];
      }
    }
  }

  __global__ void tdma(double * __restrict__ a, double * __restrict__ b, double * __restrict__ c,
                       double * __restrict__ p, double * __restrict__ work3d,
                       const int jj, const int kk,
                       const int imax, const int jmax, const int kmax)
  {
    const int i = blockIdx.x*blockDim.x + threadIdx.x;
    const int j = blockIdx.y*blockDim.y + threadIdx.y;

    if(i < imax && j < jmax)
    {
      const int ij = i + j*jj;
      int k,ijk;

      double work2d = b[ij];
      p[ij] /= work2d;

      for(k=1; k<kmax; k++)
      {
        ijk = ij + k*kk;
        work3d[ijk] = c[k-1] / work2d;
        work2d = b[ijk] - a[k]*work3d[ijk];
        p[ijk] -= a[k]*p[ijk-kk];
        p[ijk] /= work2d;
      }

      for(k=kmax-2; k>=0; k--)
      {
        ijk = ij + k*kk;
        p[ijk] -= work3d[ijk+kk]*p[ijk+kk];
      }
    }
  }

  __global__ void complex_double_x(cufftDoubleComplex * __restrict__ cdata, double * __restrict__ ddata, const unsigned int itot, const unsigned int jtot, unsigned int kk, unsigned int kki, bool forward)
  {
    int i = blockIdx.x*blockDim.x + threadIdx.x;
    int j = blockIdx.y*blockDim.y + threadIdx.y;
    int k = blockIdx.z;

    int ij   = i + j*itot + k*kk;         // index real part in ddata
    int ij2  = (itot-i) + j*itot + k*kk;  // index complex part in ddata
    int imax = itot/2+1;
    int ijc  = i + j*imax + k*kki;        // index in cdata

    if((j < jtot) && (i < imax))
    {
      if(forward) // complex -> double
      {
        ddata[ij]  = cdata[ijc].x;
        if(i>0 && i<imax-1)
          ddata[ij2] = cdata[ijc].y;
      }
      else // double -> complex
      {
        cdata[ijc].x = ddata[ij];
        if(i>0 && i<imax-1)
          cdata[ijc].y = ddata[ij2];
      }
    }
  }

  __global__ void complex_double_y(cufftDoubleComplex * __restrict__ cdata, double * __restrict__ ddata, const unsigned int itot, const unsigned int jtot, unsigned int kk, unsigned int kkj, bool forward)
  {
    int i = blockIdx.x*blockDim.x + threadIdx.x;
    int j = blockIdx.y*blockDim.y + threadIdx.y;
    int k = blockIdx.z;

    int ij   = i + j*itot + k*kk;        // index real part in ddata
    int ij2  = i + (jtot-j)*itot + k*kk;    // index complex part in ddata
    int jmax = jtot/2+1;
    int ijc  = i + j*itot + k*kkj;

    if((i < itot) && (j < jmax))
    {
      if(forward) // complex -> double
      {
        ddata[ij] = cdata[ijc].x;
        if(j>0 && j<jmax-1)
          ddata[ij2] = cdata[ijc].y;
      }
      else // double -> complex
      {
        cdata[ijc].x = ddata[ij];
        if(j>0 && j<jmax-1)
          cdata[ijc].y = ddata[ij2];
      }
    }
  }

   __global__ void normalize(double * const __restrict__ data, const int itot, const int jtot, const int ktot, const double in)
  {
    int i = blockIdx.x*blockDim.x + threadIdx.x;
    int j = blockIdx.y*blockDim.y + threadIdx.y;
    int k = blockIdx.z;

    int ijk = i + j*itot + k*itot*jtot;
    if((i < itot) && (j < jtot) && (k < ktot))
      data[ijk] = data[ijk] * in;
  }

  __global__ void calcdivergence(double * __restrict__ u, double * __restrict__ v, double * __restrict__ w,
                                 double * __restrict__ div, double * __restrict__ dzi,
                                 double * __restrict__ rhoref, double * __restrict__ rhorefh,
                                 double dxi, double dyi,
                                 int jj, int kk, int istart, int jstart, int kstart,
                                 int iend, int jend, int kend)
  {
    int i = blockIdx.x*blockDim.x + threadIdx.x + istart;
    int j = blockIdx.y*blockDim.y + threadIdx.y + jstart;
    int k = blockIdx.z + kstart;
    int ii = 1;

    if(i < iend && j < jend && k < kend)
    {
      int ijk = i + j*jj + k*kk;
      div[ijk] = rhoref[k]*((u[ijk+ii]-u[ijk])*dxi + (v[ijk+jj]-v[ijk])*dyi)
               + (rhorefh[k+1]*w[ijk+kk]-rhorefh[k]*w[ijk])*dzi[k];
    }
  }
} // End namespace.

void Pres2::prepareDevice()
{
  const int kmemsize = grid->kmax*sizeof(double);
  const int imemsize = grid->itot*sizeof(double);
  const int jmemsize = grid->jtot*sizeof(double);

  const int ijmemsize = grid->imax*grid->jmax*sizeof(double);

  cudaSafeCall(cudaMalloc((void**)&bmati_g, imemsize  ));
  cudaSafeCall(cudaMalloc((void**)&bmatj_g, jmemsize  ));
  cudaSafeCall(cudaMalloc((void**)&a_g, kmemsize      ));
  cudaSafeCall(cudaMalloc((void**)&c_g, kmemsize      ));
  cudaSafeCall(cudaMalloc((void**)&work2d_g, ijmemsize));

  cudaSafeCall(cudaMemcpy(bmati_g, bmati, imemsize, cudaMemcpyHostToDevice   ));
  cudaSafeCall(cudaMemcpy(bmatj_g, bmatj, jmemsize, cudaMemcpyHostToDevice   ));
  cudaSafeCall(cudaMemcpy(a_g, a, kmemsize, cudaMemcpyHostToDevice           ));
  cudaSafeCall(cudaMemcpy(c_g, c, kmemsize, cudaMemcpyHostToDevice           ));
  cudaSafeCall(cudaMemcpy(work2d_g, work2d, ijmemsize, cudaMemcpyHostToDevice));

  // Make cuFFT plan
  int rank      = 1;

  // Double input
  int i_ni[]    = {grid->itot};
  int i_nj[]    = {grid->jtot};
  int i_istride = 1;
  int i_jstride = grid->itot;
  int i_idist   = grid->itot;
  int i_jdist   = 1;

  // Double-complex output
  int o_ni[]    = {grid->itot/2+1};
  int o_nj[]    = {grid->jtot/2+1};
  int o_istride = 1;
  int o_jstride = grid->itot;
  int o_idist   = grid->itot/2+1;
  int o_jdist   = 1;

  // NOTES :)
  // cufftPlanMany(cufftHandle *plan, int rank, int *n, int *inembed, int istride, int idist, int *onembed, int ostride, int odist, cufftType type, int batch);
  // plan       Pointer to a cufftHandle object
  // rank       Dimensionality of the transform (1, 2, or 3)
  // n	        Array of size rank, describing the size of each dimension
  // ** inembed    Pointer of size rank that indicates the storage dimensions of the input data in memory. If set to NULL all other advanced data layout parameters are ignored.
  // istride    Indicates the distance between two successive input elements in the least significant (i.e., innermost) dimension
  // idist      Indicates the distance between the first element of two consecutive signals in a batch of the input data
  // ** onembed    Pointer of size rank that indicates the storage dimensions of the output data in memory. If set to NULL all other advanced data layout parameters are ignored.
  // ostride    Indicates the distance between two successive output elements in the output array in the least significant (i.e., innermost) dimension
  // odist      Indicates the distance between the first element of two consecutive signals in a batch of the output data
  // type       The transform data type (e.g., CUFFT_R2C for single precision real to complex)
  // batch      Batch size for this transform

  // Forward FFTs
  Pres2_g::cudaCheckFFTPlan(cufftPlanMany(&iplanf,   rank, i_ni, i_ni, i_istride, i_idist,        o_ni, o_istride, o_idist,        CUFFT_D2Z, grid->jtot*grid->ktot));
  Pres2_g::cudaCheckFFTPlan(cufftPlanMany(&jplanf,   rank, i_nj, i_nj, i_istride, grid->jtot,     o_nj, o_istride, grid->jtot/2+1, CUFFT_D2Z, grid->itot*grid->ktot));
  Pres2_g::cudaCheckFFTPlan(cufftPlanMany(&jplanf2d, rank, i_nj, i_nj, i_jstride, i_jdist,        o_nj, o_jstride, o_jdist,        CUFFT_D2Z, grid->itot)); // old y-dir fft, per slice

  // Backward FFTs
  // NOTE: input size is always the 'logical' size of the FFT, so itot or jtot, not itot/2+1 or jtot/2+1
  Pres2_g::cudaCheckFFTPlan(cufftPlanMany(&iplanb,   rank, i_ni, o_ni, o_istride, o_idist,        i_ni, i_istride, i_idist,        CUFFT_Z2D, grid->jtot*grid->ktot));
  Pres2_g::cudaCheckFFTPlan(cufftPlanMany(&jplanb,   rank, i_nj, o_nj, o_istride, grid->jtot/2+1, i_nj, i_istride, grid->jtot,     CUFFT_Z2D, grid->itot*grid->ktot));
  Pres2_g::cudaCheckFFTPlan(cufftPlanMany(&jplanb2d, rank, i_nj, o_nj, o_jstride, o_jdist,        i_nj, i_jstride, i_jdist,        CUFFT_Z2D, grid->itot));
}

void Pres2::clearDevice()
{
  cudaSafeCall(cudaFree(bmati_g ));
  cudaSafeCall(cudaFree(bmatj_g ));
  cudaSafeCall(cudaFree(a_g     ));
  cudaSafeCall(cudaFree(c_g     ));
  cudaSafeCall(cudaFree(work2d_g));

  cufftDestroy(iplanf);
  cufftDestroy(jplanf);
  cufftDestroy(iplanb);
  cufftDestroy(jplanb);
}

#ifdef USECUDA
void Pres2::exec(double dt)
{
  int gridi, gridj;
  const int blocki = grid->iThreadBlock;
  const int blockj = grid->jThreadBlock;
  gridi = grid->imax/blocki + (grid->imax%blocki > 0);
  gridj = grid->jmax/blockj + (grid->jmax%blockj > 0);

  // 3D grid
  dim3 gridGPU (gridi,  gridj,  grid->kmax);
  dim3 blockGPU(blocki, blockj, 1);

  // 2D grid
  dim3 grid2dGPU (gridi,  gridj);
  dim3 block2dGPU(blocki, blockj);

  // Square grid for transposes 
  const int gridiT = grid->imax/TILE_DIM + (grid->imax%TILE_DIM > 0);
  const int gridjT = grid->jmax/TILE_DIM + (grid->jmax%TILE_DIM > 0);
  dim3 gridGPUTf(gridiT, gridjT, grid->ktot); // Transpose ijk to jik
  dim3 gridGPUTb(gridjT, gridiT, grid->ktot); // Transpose jik to ijk
  dim3 blockGPUT(TILE_DIM, TILE_DIM, 1);

  // Transposed grid
  gridi = grid->jmax/blocki + (grid->jmax%blocki > 0);
  gridj = grid->imax/blockj + (grid->imax%blockj > 0);
  dim3 gridGPUji (gridi,  gridj,  grid->kmax);

  const int kk = grid->itot*grid->jtot;
  const int kki = (grid->itot/2+1)*grid->jtot; // Size complex slice FFT - x direction
  const int kkj = (grid->jtot/2+1)*grid->itot; // Size complex slice FFT - y direction

  const int offs = grid->memoffset;


  // calculate the cyclic BCs first
  grid->boundaryCyclic_g(&fields->ut->data_g[offs]);
  grid->boundaryCyclic_g(&fields->vt->data_g[offs]);
  grid->boundaryCyclic_g(&fields->wt->data_g[offs]);

  Pres2_g::presin<<<gridGPU, blockGPU>>>(fields->sd["p"]->data_g,
                                         &fields->u->data_g[offs],  &fields->v->data_g[offs],  &fields->w->data_g[offs],
                                         &fields->ut->data_g[offs], &fields->vt->data_g[offs], &fields->wt->data_g[offs],
                                         grid->dzi_g, fields->rhoref_g, fields->rhorefh_g,
                                         1./grid->dx, 1./grid->dy, 1./dt,
                                         grid->icellsp, grid->ijcellsp, grid->imax, grid->imax*grid->jmax,
                                         grid->imax, grid->jmax, grid->kmax,
                                         grid->igc, grid->jgc, grid->kgc);
  cudaCheckError();

  // Forward FFT in the x-direction, single batch over entire 3D field
  cufftExecD2Z(iplanf, (cufftDoubleReal*)fields->sd["p"]->data_g, (cufftDoubleComplex*)fields->atmp["tmp1"]->data_g);
  cudaThreadSynchronize();

  // Transform complex to double output. Allows for creating parallel cuda version at a later stage
  Pres2_g::complex_double_x<<<gridGPU,blockGPU>>>((cufftDoubleComplex*)fields->atmp["tmp1"]->data_g, fields->sd["p"]->data_g, grid->itot, grid->jtot, kk, kki,  true);
  cudaCheckError();

  // Forward FFT in the y-direction.
  if(grid->jtot > 1)
  {
    // For small grid sizes, transposing the domain followed by a batch FFT over the 
    // entire domain is a lot faster. Tipping point is somewhere in between 128-256 grid points
    if((grid->itot <= 128) || (grid->jtot <= 128))
    {
      Pres2_g::transpose<<<gridGPUTf, blockGPUT>>>(fields->atmp["tmp2"]->data_g, fields->sd["p"]->data_g, grid->itot, grid->jtot, grid->ktot); 
      cudaCheckError();

      cufftExecD2Z(jplanf, (cufftDoubleReal*)fields->atmp["tmp2"]->data_g, (cufftDoubleComplex*)fields->atmp["tmp1"]->data_g);
      cudaThreadSynchronize();

      // Transform complex to double output. Allows for creating parallel cuda version at a later stage
      Pres2_g::complex_double_x<<<gridGPUji,blockGPU>>>((cufftDoubleComplex*)fields->atmp["tmp1"]->data_g, fields->sd["p"]->data_g, grid->jtot, grid->itot, kk, kkj,  true);
      cudaCheckError();

      Pres2_g::transpose<<<gridGPUTb, blockGPUT>>>(fields->atmp["tmp1"]->data_g, fields->sd["p"]->data_g, grid->jtot, grid->itot, grid->ktot); 
      cudaSafeCall(cudaMemcpy(fields->sd["p"]->data_g, fields->atmp["tmp1"]->data_g, grid->ncellsp*sizeof(double), cudaMemcpyDeviceToDevice));
      cudaCheckError();
    }
    else
    {
      for (int k=0; k<grid->ktot; ++k)
      {
        int ijk  = k*kk;
        int ijk2 = 2*k*kkj;
        cufftExecD2Z(jplanf2d, (cufftDoubleReal*)&fields->sd["p"]->data_g[ijk], (cufftDoubleComplex*)&fields->atmp["tmp1"]->data_g[ijk2]);
      }

      cudaThreadSynchronize();
      cudaCheckError();

      // Transform complex to double output.
      Pres2_g::complex_double_y<<<gridGPU,blockGPU>>>((cufftDoubleComplex*)fields->atmp["tmp1"]->data_g, fields->sd["p"]->data_g, grid->itot, grid->jtot, kk, kkj, true);
      cudaCheckError();
    }
  }

  Pres2_g::solvein<<<gridGPU, blockGPU>>>(fields->sd["p"]->data_g,
                                          fields->atmp["tmp1"]->data_g, fields->atmp["tmp2"]->data_g,
                                          a_g, c_g,
                                          grid->dz_g, fields->rhoref_g, bmati_g, bmatj_g,
                                          grid->imax, grid->imax*grid->jmax,
                                          grid->imax, grid->jmax, grid->kmax,
                                          grid->kstart);
  cudaCheckError();

  Pres2_g::tdma<<<grid2dGPU, block2dGPU>>>(a_g, fields->atmp["tmp2"]->data_g, c_g,
                                           fields->sd["p"]->data_g, fields->atmp["tmp1"]->data_g,
                                           grid->imax, grid->imax*grid->jmax,
                                           grid->imax, grid->jmax, grid->kmax);
  cudaCheckError();

  // Backward FFT in the y-direction.
  if(grid->jtot > 1)
  {
    // For small grid sizes, transposing the domain followed by a batch FFT over the 
    // entire domain is a lot faster. Tipping point is somewhere in between 128-256 grid points
    if((grid->itot <= 128) || (grid->jtot <= 128))
    {
      Pres2_g::transpose<<<gridGPUTf, blockGPUT>>>(fields->atmp["tmp2"]->data_g, fields->sd["p"]->data_g, grid->itot, grid->jtot, grid->ktot); 
      cudaCheckError();

      // Transform double -> complex
      Pres2_g::complex_double_x<<<gridGPUji,blockGPU>>>((cufftDoubleComplex*)fields->atmp["tmp1"]->data_g, fields->atmp["tmp2"]->data_g, grid->jtot, grid->itot, kk, kkj, false);
      cudaCheckError();

      cufftExecZ2D(jplanb, (cufftDoubleComplex*)fields->atmp["tmp1"]->data_g, (cufftDoubleReal*)fields->sd["p"]->data_g);
      cudaThreadSynchronize();
      cudaCheckError();

      Pres2_g::transpose<<<gridGPUTb, blockGPUT>>>(fields->atmp["tmp1"]->data_g, fields->sd["p"]->data_g, grid->jtot, grid->itot, grid->ktot); 
      cudaCheckError();
      cudaSafeCall(cudaMemcpy(fields->sd["p"]->data_g, fields->atmp["tmp1"]->data_g, grid->ncellsp*sizeof(double), cudaMemcpyDeviceToDevice));
      cudaCheckError();
    }
    else
    {
      Pres2_g::complex_double_y<<<gridGPU,blockGPU>>>((cufftDoubleComplex*)fields->atmp["tmp1"]->data_g, fields->sd["p"]->data_g, grid->itot, grid->jtot, kk, kkj, false);
      cudaCheckError();

      // FFTs per slice
      for (int k=0; k<grid->ktot; ++k)
      {
        int ijk = k*kk;
        int ijk2 = 2*k*kkj;
        cufftExecZ2D(jplanb2d, (cufftDoubleComplex*)&fields->atmp["tmp1"]->data_g[ijk2], (cufftDoubleReal*)&fields->sd["p"]->data_g[ijk]);
      }

      cudaThreadSynchronize();
      cudaCheckError();
    }
  }

  // Backward FFT in the x-direction
  Pres2_g::complex_double_x<<<gridGPU,blockGPU>>>((cufftDoubleComplex*)fields->atmp["tmp1"]->data_g, fields->sd["p"]->data_g, grid->itot, grid->jtot, kk, kki,  false);
  cudaCheckError();

  // Batch FFT over entire domain
  cufftExecZ2D(iplanb, (cufftDoubleComplex*)fields->atmp["tmp1"]->data_g, (cufftDoubleReal*)fields->sd["p"]->data_g);
  cudaThreadSynchronize();
  cudaCheckError();

  // Normalize output
  Pres2_g::normalize<<<gridGPU,blockGPU>>>(fields->sd["p"]->data_g, grid->itot, grid->jtot, grid->ktot, 1./(grid->itot*grid->jtot));
  cudaCheckError();

  cudaSafeCall(cudaMemcpy(fields->atmp["tmp1"]->data_g, fields->sd["p"]->data_g, grid->ncellsp*sizeof(double), cudaMemcpyDeviceToDevice));

  Pres2_g::solveout<<<gridGPU, blockGPU>>>(&fields->sd["p"]->data_g[offs], fields->atmp["tmp1"]->data_g,
                                           grid->imax, grid->imax*grid->jmax,
                                           grid->icellsp, grid->ijcellsp,
                                           grid->istart, grid->jstart, grid->kstart,
                                           grid->imax, grid->jmax, grid->kmax);
  cudaCheckError();

  grid->boundaryCyclic_g(&fields->sd["p"]->data_g[offs]);

  Pres2_g::presout<<<gridGPU, blockGPU>>>(&fields->ut->data_g[offs], &fields->vt->data_g[offs], &fields->wt->data_g[offs],
                                          &fields->sd["p"]->data_g[offs],
                                          grid->dzhi_g, 1./grid->dx, 1./grid->dy,
                                          grid->icellsp, grid->ijcellsp,
                                          grid->istart, grid->jstart, grid->kstart,
                                          grid->iend, grid->jend, grid->kend);
  cudaCheckError();
}
#endif

#ifdef USECUDA
double Pres2::checkDivergence()
{
  const int blocki = grid->iThreadBlock;
  const int blockj = grid->jThreadBlock;
  const int gridi  = grid->imax/blocki + (grid->imax%blocki > 0);
  const int gridj  = grid->jmax/blockj + (grid->jmax%blockj > 0);

  double divmax = 0;

  dim3 gridGPU (gridi, gridj, grid->kcells);
  dim3 blockGPU(blocki, blockj, 1);

  const double dxi = 1./grid->dx;
  const double dyi = 1./grid->dy;

  const int offs = grid->memoffset;

  Pres2_g::calcdivergence<<<gridGPU, blockGPU>>>(&fields->u->data_g[offs], &fields->v->data_g[offs], &fields->w->data_g[offs],
                                                 &fields->atmp["tmp1"]->data_g[offs], grid->dzi_g,
                                                 fields->rhoref_g, fields->rhorefh_g, dxi, dyi,
                                                 grid->icellsp, grid->ijcellsp,
                                                 grid->istart,  grid->jstart, grid->kstart,
                                                 grid->iend,    grid->jend,   grid->kend);
  cudaCheckError();

  divmax = grid->getMax_g(&fields->atmp["tmp1"]->data_g[offs], fields->atmp["tmp2"]->data_g);
  grid->getMax(&divmax);

  return divmax;
}
#endif
