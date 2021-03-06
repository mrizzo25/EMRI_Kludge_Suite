/*
This is the central piece of code. This file implements a class
(interface in gpuadder.hh) that takes data in on the cpu side, copies
it to the gpu, and exposes functions (increment and retreive) that let
you perform actions with the GPU

This class will get translated into python via swig
*/

#include <kernel.hh>
#include <AAK_manager.hh>
#include <assert.h>
#include <iostream>
#include <stdlib.h>
#include "cuComplex.h"
#include "cublas_v2.h"
#include <cufft.h>
#include <complex.h>

#include "Globals.h"
#include "GKTrajFast.h"
#include "KSParMap.h"
#include "KSTools.h"
#include "gpuAAK.h"
#include "interpolate.hh"

using namespace std;

#define BATCH 1

#define gpuErrchk(ans) { gpuAssert((ans), __FILE__, __LINE__); }
inline void gpuAssert(cudaError_t code, const char *file, int line, bool abort=true)
{
   if (code != cudaSuccess)
   {
      fprintf(stderr,"GPUassert: %s %s %d\n", cudaGetErrorString(code), file, line);
      if (abort) exit(code);
   }
}


GPUAAK::GPUAAK (double T_fit_,
    int init_length_,
    int length_,
    double init_dt_,
    double dt_,
    bool LISA_,
    bool backint_){

    T_fit = T_fit_;
    init_length = init_length_;
    length = length_;
    init_dt = init_dt_;
    dt = dt_;
    LISA = LISA_;
    backint = backint_;

    to_gpu = 1;

     fft_length = ((int) (length/2)) + 1;

    cudaError_t err;

    // DECLARE ALL THE  NECESSARY STRUCTS

    tvec = new double[init_length+1];
    evec = new double[init_length+1];
    vvec = new double[init_length+1];
    Mvec = new double[init_length+1];
    Svec = new double[init_length+1];

        size_t numBytes_ = 0;
        trajectories = createInterpArrayContainer(&numBytes_, 4, init_length+1);
        numBytes = numBytes_;
        d_trajectories = createInterpArrayContainer_gpu(numBytes, trajectories);

        d_evec = trajectories[0];
        d_vvec = trajectories[1];
        d_Mvec = trajectories[2];
        d_Svec = trajectories[3];

      double_size = length*sizeof(double);
      gpuErrchk(cudaMalloc(&d_t, (length+2)*sizeof(double)));

      gpuErrchk(cudaMalloc(&d_hI, (length+2)*sizeof(double)));
      gpuErrchk(cudaMalloc(&d_hII, (length+2)*sizeof(double)));

      gpuErrchk(cudaMalloc(&d_data_channel1, fft_length*sizeof(cuDoubleComplex)));
      gpuErrchk(cudaMalloc(&d_data_channel2, fft_length*sizeof(cuDoubleComplex)));


      gpuErrchk(cudaMalloc(&d_noise_channel1_inv, fft_length*sizeof(double)));
      gpuErrchk(cudaMalloc(&d_noise_channel2_inv, fft_length*sizeof(double)));

      double_plus_one_size = (length+1)*sizeof(double);  // TODO reduce size properly
      gpuErrchk(cudaMalloc(&d_tvec, (length+1)*sizeof(double)));

      gpuErrchk(cudaMalloc(&e_out, (length+1)*sizeof(double)));
      gpuErrchk(cudaMalloc(&v_out, (length+1)*sizeof(double)));
      gpuErrchk(cudaMalloc(&M_out, (length+1)*sizeof(double)));
      gpuErrchk(cudaMalloc(&S_out, (length+1)*sizeof(double)));
      gpuErrchk(cudaMalloc(&gimdot_out, (length+1)*sizeof(double)));
      gpuErrchk(cudaMalloc(&nu_out, (length+1)*sizeof(double)));
      gpuErrchk(cudaMalloc(&alpdot_out, (length+1)*sizeof(double)));
      gpuErrchk(cudaMalloc(&gim_out, (length+1)*sizeof(double)));
      gpuErrchk(cudaMalloc(&Phi_out, (length+1)*sizeof(double)));
      gpuErrchk(cudaMalloc(&alp_out, (length+1)*sizeof(double)));



      NUM_THREADS = 256;
      num_blocks = std::ceil((init_length + 1 + NUM_THREADS -1)/NUM_THREADS);
      num_blocks_wave = std::ceil((length + 1 + NUM_THREADS -1)/NUM_THREADS);

     // cufftHandle plan_;
      //plan = plan_;

      //cufftComplex *data;

      printf("FFT plan %d\n", length);
      if (cufftPlan1d(&plan, length, CUFFT_D2Z, BATCH) != CUFFT_SUCCESS){
        	fprintf(stderr, "CUFFT error: Plan creation failed");
        	return;	}

    stat = cublasCreate(&handle);
  if (stat != CUBLAS_STATUS_SUCCESS) {
          printf ("CUBLAS initialization failed\n");
          exit(0);
      }

    interp.alloc_arrays(init_length + 1, 4);

}

void GPUAAK::input_data(cmplx *hI_f_, cmplx *hII_f_, double *channel_ASDinv1_, double *channel_ASDinv2_, int len)
{

    assert(len == fft_length);

    data_channel1 = hI_f_;
    data_channel2 = hII_f_;
    noise_channel1_inv = channel_ASDinv1_;
    noise_channel2_inv = channel_ASDinv2_;

    gpuErrchk(cudaMemcpy(d_data_channel1, hI_f_, fft_length*sizeof(cuDoubleComplex), cudaMemcpyHostToDevice));
    gpuErrchk(cudaMemcpy(d_data_channel2, hII_f_, fft_length*sizeof(cuDoubleComplex), cudaMemcpyHostToDevice));

    gpuErrchk(cudaMemcpy(d_noise_channel1_inv, channel_ASDinv1_, fft_length*sizeof(double), cudaMemcpyHostToDevice));
    gpuErrchk(cudaMemcpy(d_noise_channel2_inv, channel_ASDinv2_, fft_length*sizeof(double), cudaMemcpyHostToDevice));


}

void GPUAAK::gpu_gen_AAK(
    double iota_,
    double s_,
    double p_,
    double e_,
    double M_,
    double mu_,
    double gamma_,
    double psi_,
    double alph_,
    double theta_S_,
    double phi_S_,
    double theta_K_,
    double phi_K_,
    double D_){

    /*cudaEvent_t start, stop;
    cudaEventCreate(&start);
    cudaEventCreate(&stop);
    cudaEventRecord(start);*/
    GPUAAK::run_phase_trajectory(
        iota_,
        s_,
        p_,
        e_,
        M_,
        mu_,
        gamma_,
        psi_,
        alph_,
        theta_S_,
        phi_S_,
        theta_K_,
        phi_K_,
        D_);

    /*cudaEventRecord(stop);
    cudaEventSynchronize(stop);
    float milliseconds = 0;
    cudaEventElapsedTime(&milliseconds, start, stop);
    printf("time cpu: %lf\n", milliseconds/1000.0);*/



    //cudaEventRecord(start);
    // Initialize inputs
    // ----- number of modes summed -----
    int nmodes=(int)(30*par[3]);
    if (par[3]<0.135) nmodes=4;
    // ----------

    zeta=par[0]/D/Gpc; // M/D
    cudaError_t err;

    //for (int i=0; i<temp_length; i++){
    //    printf("%e %e %e %e %e\n", tvec[i], evec[i], vvec[i], Mvec[i], Svec[i]);
    //}
    //printf("%d, %e, %e\n", temp_length, interp_timestep, t_clip);
    gpuErrchk(cudaMemcpy(d_tvec, tvec, (temp_length)*sizeof(double), cudaMemcpyHostToDevice));

    gpuErrchk(cudaMemcpy(d_evec.array, evec, (temp_length)*sizeof(double), cudaMemcpyHostToDevice));
    gpuErrchk(cudaMemcpy(d_vvec.array, vvec, (temp_length)*sizeof(double), cudaMemcpyHostToDevice));

    gpuErrchk(cudaMemcpy(d_Mvec.array, Mvec, (temp_length)*sizeof(double), cudaMemcpyHostToDevice));

    gpuErrchk(cudaMemcpy(d_Svec.array, Svec, (temp_length)*sizeof(double), cudaMemcpyHostToDevice));

    //gpuErrchk(cudaMemcpy(d_trajectories, trajectories, numBytes, cudaMemcpyHostToDevice));

    //for (int i=0; i<100; i++) printf("%.18e\n", gimdotvec[i]);
    //printf("\n\n\nBREAK BREAK\n\n\n");

    interp.setup(d_trajectories, d_tvec, temp_length, 4);

    int run_num = (int) std::ceil(t_clip/dt);

    int run_blocks = std::ceil((run_num + 1 + NUM_THREADS -1)/NUM_THREADS);

    //printf("%d %d\n", run_num, run_blocks);
    produce_phasing<<<run_blocks, NUM_THREADS>>>(e_out, v_out, M_out, S_out, gimdot_out, nu_out, alpdot_out,
                            gim_out, Phi_out, alp_out,
                         d_tvec, d_evec, d_vvec, d_Mvec, d_Svec,
                                iota,
                             temp_length,
                                 interp_timestep, dt, t_clip, run_num);

    cumsum(gim_out, gamma, run_num);
    cumsum(Phi_out, psi, run_num);
    cumsum(alp_out, alph, run_num);

    /* main: evaluate model at given frequencies */
    kernel_create_waveform<<<num_blocks_wave, NUM_THREADS>>>(d_t, d_hI, d_hII, d_tvec, e_out, v_out, M_out, S_out, gim_out, Phi_out, alp_out, nu_out, gimdot_out, iota, M_PI - theta_S, phi_S, theta_K, phi_K, LISA, init_length, length+2, nmodes, i_plunge, i_buffer, zeta, M, init_dt, dt, run_num);  //iota = lam

    cudaDeviceSynchronize();
    gpuErrchk(cudaGetLastError());

    /*printit<<<1,1>>>(d_hI, 10);
    cudaDeviceSynchronize();
    gpuErrchk(cudaGetLastError());*/
         /*double *hI = new double[length+2];
     cudaMemcpy(hI, d_data_channel1, (length+2)*sizeof(double), cudaMemcpyDeviceToHost);
     for (int i=0; i<200; i+=1){
         //if (i == fft_length-1) hI[2*i + 1] = 0.0;
         printf("%d after: , %e + %e j, %e + %e j\n", i, hI[2*i], hI[2*i + 1], data_channel1[i].real(), data_channel1[i].imag());
     }
     delete[] hI;//*/
}


void GPUAAK::run_phase_trajectory(
    double iota_,
    double s_,
    double p_,
    double e_,
    double M_,
    double mu_,
    double gamma_,
    double psi_,
    double alph_,
    double theta_S_,
    double phi_S_,
    double theta_K_,
    double phi_K_,
    double D_){

    iota = iota_;
    s = s_;
    p = p_;
    e = e_;
    M = M_;
    mu = mu_;
    gamma = gamma_;
    psi = psi_;
    alph = alph_;
    theta_S = theta_S_;
    phi_S = phi_S_;
    theta_K = theta_K_;
    phi_K = phi_K_;
    D = D_;

    clock_t ticks=clock();

    GKTrajFast gktraj3(cos(iota),s);
    gktraj3.p=p;
    gktraj3.ecc=e;
    int maxsteps=100;
    int steps=0;
    double dt_fit=min(T_fit,length*dt/SOLARMASSINSEC/M/M*mu)/(maxsteps-1);
    TrajData *traj3;
    traj3=(TrajData*)malloc((size_t)((maxsteps+1)*sizeof(TrajData)));
    gktraj3.Eccentric(dt_fit,traj3,maxsteps,steps);
    double Omega_t[3],ang[3],map_t[3],e_traj[steps],v_map[steps],M_map[steps],s_map[steps],dt_map[steps];
    double Phi;
    for(int i=1;i<=steps;i++){
      IEKG geodesic_t(traj3[i].p,traj3[i].ecc,traj3[i].cosiota,s);
      geodesic_t.Frequencies(Omega_t);
      if(i==1){
        ParAng(ang,e,iota,gamma,psi,theta_S,phi_S,theta_K,phi_K,alph,geodesic_t.zedminus);
        Phi=ang[0]; // initial mean anomaly
      }
      ParMap(map_t,Omega_t,traj3[i].p,M,s,traj3[i].ecc,iota);
      e_traj[i-1]=traj3[i].ecc;
      v_map[i-1]=map_t[0]; // mapped initial velocity in c
      M_map[i-1]=map_t[1]; // mapped BH mass in solar masses
      s_map[i-1]=map_t[2]; // mapped spin parameter a/M = S/M^2
      dt_map[i-1]=traj3[i].t*SOLARMASSINSEC*M*M/mu;
    }

    //GenWave(t,hI,hII,AAK.dt,AAK.length,e_traj,v_map,AAK.M,M_map,AAK.mu,AAK.s,s_map,AAK.D,AAK.iota,AAK.gamma,Phi,AAK.theta_S,AAK.phi_S,AAK.alpha,AAK.theta_K,AAK.phi_K,dt_map,steps,AAK.backint,AAK.LISA,false);

    par[0]=mu*SOLARMASSINSEC;
    par[1]=M_map[0]*SOLARMASSINSEC;
    par[2]=s_map[0];
    par[3]=e_traj[0];
    par[4]=iota;  // TODO: check this
    par[5]=gamma;
    par[6]=Phi;
    par[7]=theta_S;
    par[8]=phi_S;
    par[9]=theta_K;
    par[10]=phi_K;
    par[11]=alph;

    PNevolution(tvec,evec,vvec,Mvec,Svec,
                dt,length,par,
                e_traj,v_map,M,M_map,s,s_map,dt_map,
                steps,&i_plunge,&i_buffer,backint, &t_clip, &interp_timestep, &temp_length);

}


__global__ void printit(double *arr, int n)
{
    for (int i=732000; i<732500; i++)
    printf("%d %.10e\n", i, arr[i]);

}

void GPUAAK::Likelihood (double *like_out_){

    //cudaMemcpy(hI, d_hI, (length+2)*sizeof(double), cudaMemcpyDeviceToHost);
    /*cudaEvent_t start, stop;
    cudaEventCreate(&start);
    cudaEventCreate(&stop);
    cudaEventRecord(start);*/

    /*printit<<<1,1>>>(d_hI, 10);
    cudaDeviceSynchronize();
    gpuErrchk(cudaGetLastError());*/


    if (cufftExecD2Z(plan, d_hI, (cufftDoubleComplex*)d_hI) != CUFFT_SUCCESS){
    fprintf(stderr, "CUFFT error: ExecC2C Forward failed");
    return;}
    cudaDeviceSynchronize();
    gpuErrchk(cudaGetLastError());

    if (cufftExecD2Z(plan, d_hII, (cufftDoubleComplex*)d_hII) != CUFFT_SUCCESS){
    fprintf(stderr, "CUFFT error: ExecC2C Forward failed");
    return;}

    cudaDeviceSynchronize();
    gpuErrchk(cudaGetLastError());

    likelihood_prep<<<num_blocks_wave, NUM_THREADS>>>((cuDoubleComplex*)d_hI, (cuDoubleComplex*)d_hII, d_noise_channel1_inv, d_noise_channel2_inv, fft_length);
    cudaDeviceSynchronize();
    gpuErrchk(cudaGetLastError());


    //printf("checkcheckcheck\n");

     double d_h = 0.0;
     double h_h = 0.0;
     char * status;
     double res;
     cuDoubleComplex result;

         stat = cublasZdotc(handle, fft_length,
                 (cuDoubleComplex*)d_hI, 1,
                 (cuDoubleComplex*)d_data_channel1, 1,
                 &result);
         status = _cudaGetErrorEnum(stat);
          cudaDeviceSynchronize();

          if (stat != CUBLAS_STATUS_SUCCESS) {
                  exit(0);
              }
         d_h += cuCreal(result);
         //printf("channel1 d_h: %e\n", cuCreal(result));

         stat = cublasZdotc(handle, fft_length,
                 (cuDoubleComplex*)d_hII, 1,
                 (cuDoubleComplex*)d_data_channel2, 1,
                 &result);
         status = _cudaGetErrorEnum(stat);
          cudaDeviceSynchronize();

          if (stat != CUBLAS_STATUS_SUCCESS) {
                  exit(0);
              }
         d_h += cuCreal(result);
         //printf("channel2 d_h: %e\n", cuCreal(result));

        stat = cublasZdotc(handle, fft_length,
                     (cuDoubleComplex*)d_hI, 1,
                     (cuDoubleComplex*)d_hI, 1,
                     &result);
             status = _cudaGetErrorEnum(stat);
              cudaDeviceSynchronize();

              if (stat != CUBLAS_STATUS_SUCCESS) {
                      exit(0);
                  }
             h_h += cuCreal(result);
             //printf("channel1 h_h: %e\n", cuCreal(result));

             stat = cublasZdotc(handle, fft_length,
                     (cuDoubleComplex*)d_hII, 1,
                     (cuDoubleComplex*)d_hII, 1,
                     &result);
             status = _cudaGetErrorEnum(stat);
              cudaDeviceSynchronize();

              if (stat != CUBLAS_STATUS_SUCCESS) {
                      exit(0);
                  }
             h_h += cuCreal(result);
             //printf("channel2 h_h: %e\n", cuCreal(result));

    //printf("dh: %e, hh: %e\n", d_h, h_h);
     like_out_[0] = 4*d_h;
     like_out_[1] = 4*h_h;

     /*cudaEventRecord(stop);
     cudaEventSynchronize(stop);
     float milliseconds = 0;
     cudaEventElapsedTime(&milliseconds, start, stop);
     printf("time like: %lf\n\n", milliseconds/1000.0);*/
}

void GPUAAK::GetWaveform (double *t_, double* hI_, double* hII_) {
 gpuErrchk(cudaMemcpy(t_, d_t, (length+2)*sizeof(double), cudaMemcpyDeviceToHost));
 gpuErrchk(cudaMemcpy(hI_, d_hI, (length+2)*sizeof(double), cudaMemcpyDeviceToHost));
 gpuErrchk(cudaMemcpy(hII_, d_hII, (length+2)*sizeof(double), cudaMemcpyDeviceToHost));
}//*/

GPUAAK::~GPUAAK() {
  delete[] tvec;
  delete[] evec;
  delete[] vvec;
  delete[] Mvec;
  delete[] Svec;

  gpuErrchk(cudaFree(e_out));
  gpuErrchk(cudaFree(v_out));
  gpuErrchk(cudaFree(M_out));
  gpuErrchk(cudaFree(S_out));
  gpuErrchk(cudaFree(gimdot_out));
  gpuErrchk(cudaFree(nu_out));
  gpuErrchk(cudaFree(alpdot_out));
  gpuErrchk(cudaFree(gim_out));
  gpuErrchk(cudaFree(Phi_out));
  gpuErrchk(cudaFree(alp_out));

  cudaFree(d_t);
  cudaFree(d_hI);
  cudaFree(d_hII);
  cudaFree(d_tvec);
  destroyInterpArrayContainer(d_trajectories, trajectories, 9);
  cudaFree(d_data_channel1);
  cudaFree(d_data_channel2);
  cudaFree(d_noise_channel1_inv);
  cudaFree(d_noise_channel2_inv);

  cufftDestroy(plan);
  cublasDestroy(handle);

}
