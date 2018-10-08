#include "hip/hip_runtime.h"
/*
   Copyright (C) 2010-2018 The ESPResSo project

   This file is part of ESPResSo.

   ESPResSo is free software: you can redistribute it and/or modify
   it under the terms of the GNU General Public License as published by
   the Free Software Foundation, either version 3 of the License, or
   (at your option) any later version.

   ESPResSo is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with this program.  If not, see <http://www.gnu.org/licenses/>.
*/

#include "config.hpp"
#include "debug.hpp"

#include "cuda_init.hpp"
#include "cuda_interface.hpp"
#include "cuda_utils.hpp"
#include "errorhandling.hpp"
#include "nonbonded_interactions/nonbonded_interaction_data.hpp"

#include <random>

#if defined(OMPI_MPI_H) || defined(_MPI_H)
#error CU-file includes mpi.h! This should not happen!
#endif

static CUDA_global_part_vars global_part_vars_host = {0, 0, 0};
static __device__ __constant__ CUDA_global_part_vars global_part_vars_device;

/** struct for particle force */
static float *particle_forces_device = nullptr;
static float *particle_torques_device = nullptr;

/** struct for particle position and velocity */
static CUDA_particle_data *particle_data_device = nullptr;
/** struct for storing particle rn seed */
static CUDA_particle_seed *particle_seeds_device = nullptr;
/** struct for fluid composition */
static CUDA_fluid_composition *fluid_composition_device = nullptr;
/** struct for energies */
static CUDA_energy *energy_device = nullptr;

CUDA_particle_data *particle_data_host = nullptr;
float *particle_forces_host = nullptr;
CUDA_energy energy_host;
float *particle_torques_host = nullptr;

CUDA_fluid_composition *fluid_composition_host = nullptr;
#ifdef ENGINE
CUDA_v_cs *host_v_cs = nullptr;
#endif

/**cuda streams for parallel computing on cpu and gpu */
hipStream_t stream[1];

hipError_t _err;
hipError_t CU_err;

void _cuda_safe_mem(hipError_t CU_err, const char *file, unsigned int line) {
  if (hipSuccess != CU_err) {
    fprintf(stderr, "Cuda Memory error at %s:%u.\n", file, line);
    printf("CUDA error: %s\n", hipGetErrorString(CU_err));
    if (CU_err == hipErrorInvalidValue)
      fprintf(stderr, "You may have tried to allocate zero memory at %s:%u.\n",
              file, line);
    errexit();
  } else {
    CU_err = hipGetLastError();
    if (CU_err != hipSuccess) {
      fprintf(stderr,
              "Error found during memory operation. Possibly however "
              "from an failed operation before. %s:%u.\n",
              file, line);
      printf("CUDA error: %s\n", hipGetErrorString(CU_err));
      if (CU_err == hipErrorInvalidValue)
        fprintf(stderr,
                "You may have tried to allocate zero memory before %s:%u.\n",
                file, line);
      errexit();
    }
  }
}

void _cuda_check_errors(const dim3 &block, const dim3 &grid,
                        const char *function, const char *file,
                        unsigned int line) {
/** If debugging is enabled, wait for Kernels to terminate before checking for
 * errors. This removes parallelism between host and device and should only be
 * enabled while debugging. */
#ifdef CUDA_DEBUG
  hipDeviceSynchronize();
#endif
  CU_err = hipGetLastError();
  if (CU_err != hipSuccess) {
    fprintf(stderr,
            "%d: error \"%s\" calling %s with dim %d %d %d, grid %d %d "
            "%d in %s:%u\n",
            this_node, hipGetErrorString(CU_err), function, block.x, block.y,
            block.z, grid.x, grid.y, grid.z, file, line);
    errexit();
  }
}

__device__ unsigned int getThreadIndex() {

  return blockIdx.y * gridDim.x * blockDim.x + blockDim.x * blockIdx.x +
         threadIdx.x;
}

/** kernel for the initialisation of the particle force array
 * @param *particle_forces_device	    Pointer to local particle force
 * (Output)
 * @param *particle_seeds_device			Pointer to the particle
 * rn
 * seed
 * storearray (Output)
 */
__global__ void init_particle_force(float *particle_forces_device,
                                    float *particle_torques_device,
                                    CUDA_particle_seed *particle_seeds_device) {

  unsigned int part_index = getThreadIndex();

  if (part_index < global_part_vars_device.number_of_particles) {
    particle_forces_device[3 * part_index + 0] = 0.0f;
    particle_forces_device[3 * part_index + 1] = 0.0f;
    particle_forces_device[3 * part_index + 2] = 0.0f;

#ifdef ROTATION
    particle_torques_device[3 * part_index] = 0.0f;
    particle_torques_device[3 * part_index + 1] = 0.0f;
    particle_torques_device[3 * part_index + 2] = 0.0f;
#endif

    particle_seeds_device[part_index].seed =
        global_part_vars_device.seed + part_index;
  }
}

/** kernel for the initialisation of the fluid composition
 * @param *fluid_composition_device Pointer to local fluid composition (Output)
 */
__global__ void
init_fluid_composition(CUDA_fluid_composition *fluid_composition_device) {

  /* Note: these are initialized to zero and not to the fluid density because we
     cannot assume that
           particles have been created after the fluid */
  unsigned int part_index = getThreadIndex();

  if (part_index < global_part_vars_device.number_of_particles) {
    for (int ii = 0; ii < LB_COMPONENTS; ii++) {
      fluid_composition_device[part_index].weight[ii] = 0.0f;
    }
  }
}

/** kernel for the initialisation of the particle force array
 * @param *particle_forces_device	pointer to local particle force (Input)
 */
__global__ void reset_particle_force(float *particle_forces_device,
                                     float *particle_torques_device) {

  unsigned int part_index = getThreadIndex();

  if (part_index < global_part_vars_device.number_of_particles) {
    particle_forces_device[3 * part_index + 0] = 0.0f;
    particle_forces_device[3 * part_index + 1] = 0.0f;
    particle_forces_device[3 * part_index + 2] = 0.0f;
#ifdef ROTATION
    particle_torques_device[3 * part_index + 0] = 0.0f;
    particle_torques_device[3 * part_index + 1] = 0.0f;
    particle_torques_device[3 * part_index + 2] = 0.0f;
#endif
  }
}

/** change number of particles to be communicated to the GPU
 *  Note that in addition to calling this function the parameters must be
 * broadcast with either:
 * 1) cuda_bcast_global_part_params(); (when just being executed on the master
 * node) or
 * 2) MPI_Bcast(gpu_get_global_particle_vars_pointer_host(),
 * sizeof(CUDA_global_part_vars), MPI_BYTE, 0, comm_cart); (when executed on all
 * nodes)
 */
void gpu_change_number_of_part_to_comm() {
  // we only run the function if there are new particles which have been created
  // since the last call of this function

  if (global_part_vars_host.number_of_particles != n_part &&
      global_part_vars_host.communication_enabled == 1 && this_node == 0) {

    global_part_vars_host.seed = (unsigned int)std::random_device{}();
    global_part_vars_host.number_of_particles = n_part;

    cuda_safe_mem(hipMemcpyToSymbol(&global_part_vars_device,
                                     &global_part_vars_host,
                                     sizeof(CUDA_global_part_vars)));

    // if the arrays exists free them to prevent memory leaks
    if (particle_forces_host) {
      cuda_safe_mem(hipHostFree(particle_forces_host));
      particle_forces_host = nullptr;
    }
    if (particle_data_host) {
      cuda_safe_mem(hipHostFree(particle_data_host));
      particle_data_host = nullptr;
    }
    if (particle_forces_device) {
      hipFree(particle_forces_device);
      particle_forces_device = nullptr;
    }
    if (particle_data_device) {
      hipFree(particle_data_device);
      particle_data_device = nullptr;
    }
    if (particle_seeds_device) {
      cuda_safe_mem(hipFree(particle_seeds_device));
      particle_seeds_device = nullptr;
    }
#ifdef ENGINE
    if (host_v_cs) {
      hipHostFree(host_v_cs);
      host_v_cs = nullptr;
    }
#endif
#if (defined DIPOLES || defined ROTATION)
    if (particle_torques_host) {
      hipHostFree(particle_torques_host);
      particle_torques_host = nullptr;
    }
#endif
#ifdef SHANCHEN
    if (fluid_composition_host) {
      cuda_safe_mem(hipHostFree(fluid_composition_host));
      fluid_composition_host = nullptr;
    }
    if (fluid_composition_device) {
      cuda_safe_mem(hipFree(fluid_composition_device));
      fluid_composition_device = nullptr;
    }
#endif

#ifdef ROTATION
    if (particle_torques_device) {
      cuda_safe_mem(hipFree(particle_torques_device));
      particle_torques_device = nullptr;
    }
#endif

    if (global_part_vars_host.number_of_particles) {

      /**pinned memory mode - use special function to get OS-pinned memory*/
      cuda_safe_mem(hipHostMalloc((void **)&particle_data_host,
                                  global_part_vars_host.number_of_particles *
                                      sizeof(CUDA_particle_data),
                                  hipHostMallocWriteCombined));
      cuda_safe_mem(hipHostMalloc(
          (void **)&particle_forces_host,
          3 * global_part_vars_host.number_of_particles * sizeof(float),
          hipHostMallocWriteCombined));

#ifdef ENGINE
      cuda_safe_mem(hipHostMalloc((void **)&host_v_cs,
                                  global_part_vars_host.number_of_particles *
                                      sizeof(CUDA_v_cs),
                                  hipHostMallocWriteCombined));
#endif
#if (defined DIPOLES || defined ROTATION)
      hipHostMalloc((void **)&particle_torques_host,
                    global_part_vars_host.number_of_particles * 3 *
                        sizeof(float),
                    hipHostMallocWriteCombined);
#endif

#ifdef SHANCHEN
      cuda_safe_mem(hipHostMalloc((void **)&fluid_composition_host,
                                  global_part_vars_host.number_of_particles *
                                      sizeof(CUDA_fluid_composition),
                                  hipHostMallocWriteCombined));
#endif

      cuda_safe_mem(hipMalloc((void **)&particle_forces_device,
                               3 * global_part_vars_host.number_of_particles *
                                   sizeof(float)));
#ifdef ROTATION
      cuda_safe_mem(hipMalloc((void **)&particle_torques_device,
                               3 * global_part_vars_host.number_of_particles *
                                   sizeof(float)));
#endif

      cuda_safe_mem(hipMalloc((void **)&particle_data_device,
                               global_part_vars_host.number_of_particles *
                                   sizeof(CUDA_particle_data)));
      cuda_safe_mem(hipMalloc((void **)&particle_seeds_device,
                               global_part_vars_host.number_of_particles *
                                   sizeof(CUDA_particle_seed)));
#ifdef SHANCHEN
      cuda_safe_mem(hipMalloc((void **)&fluid_composition_device,
                               global_part_vars_host.number_of_particles *
                                   sizeof(CUDA_fluid_composition)));
#endif

      /** values for the particle kernel */
      int threads_per_block_particles = 64;
      int blocks_per_grid_particles_y = 4;
      int blocks_per_grid_particles_x =
          (global_part_vars_host.number_of_particles +
           threads_per_block_particles * blocks_per_grid_particles_y - 1) /
          (threads_per_block_particles * blocks_per_grid_particles_y);
      dim3 dim_grid_particles = make_uint3(blocks_per_grid_particles_x,
                                           blocks_per_grid_particles_y, 1);

      KERNELCALL(init_particle_force, dim_grid_particles,
                 threads_per_block_particles,
                 (particle_forces_device, particle_torques_device,
                  particle_seeds_device));

#ifdef SHANCHEN
      KERNELCALL(init_fluid_composition, dim_grid_particles,
                 threads_per_block_particles, (fluid_composition_device));
#endif
    }
  }
}

/** setup and call particle reallocation from the host
 *  Note that in addition to calling this function the parameters must be
 * broadcast with either:
 * 1) cuda_bcast_global_part_params(); (when just being executed on the master
 * node) or
 * 2) MPI_Bcast(gpu_get_global_particle_vars_pointer_host(),
 * sizeof(CUDA_global_part_vars), MPI_BYTE, 0, comm_cart); (when executed on all
 * nodes)
 */
void gpu_init_particle_comm() {
  if (this_node == 0 && global_part_vars_host.communication_enabled == 0) {
    if (cuda_get_n_gpus() == -1) {
      runtimeErrorMsg()
          << "Unable to initialize CUDA as no sufficient GPU is available.";
      errexit();
    }
    if (cuda_get_n_gpus() > 1) {
      runtimeWarningMsg() << "More than one GPU detected, please note ESPResSo "
                             "uses device 0 by default regardless of usage or "
                             "capability. The GPU to be used can be modified "
                             "by setting System.cuda_init_handle.device.";
      if (cuda_check_gpu(0) != ES_OK) {
        runtimeWarningMsg()
            << "CUDA device 0 is not capable of running ESPResSo but is used "
               "by default. Espresso has detected a CUDA capable card but it "
               "is not the one used by ESPResSo by default. Please set the "
               "GPU to use by setting System.cuda_init_handle.device. A list "
               "of avalable GPUs is available through "
               "System.cuda_init_handle.device_list.";
      }
    }
  }
  global_part_vars_host.communication_enabled = 1;
  gpu_change_number_of_part_to_comm();
}

CUDA_particle_data *gpu_get_particle_pointer() { return particle_data_device; }
CUDA_global_part_vars *gpu_get_global_particle_vars_pointer_host() {
  return &global_part_vars_host;
}
CUDA_global_part_vars *gpu_get_global_particle_vars_pointer() {
  return &global_part_vars_device;
}
float *gpu_get_particle_force_pointer() { return particle_forces_device; }
CUDA_energy *gpu_get_energy_pointer() { return energy_device; }
float *gpu_get_particle_torque_pointer() { return particle_torques_device; }

CUDA_particle_seed *gpu_get_particle_seed_pointer() {
  return particle_seeds_device;
}

CUDA_fluid_composition *gpu_get_fluid_composition_pointer() {
  return fluid_composition_device;
}

void copy_part_data_to_gpu(ParticleRange particles) {
  COMM_TRACE(printf("global_part_vars_host.communication_enabled = %d && "
                    "global_part_vars_host.number_of_particles = %d\n",
                    global_part_vars_host.communication_enabled,
                    global_part_vars_host.number_of_particles));
  if (global_part_vars_host.communication_enabled == 1 &&
      global_part_vars_host.number_of_particles) {
    cuda_mpi_get_particles(particles, particle_data_host);

    /** get espresso md particle values*/
    if (this_node == 0)
      hipMemcpyAsync(particle_data_device, particle_data_host,
                      global_part_vars_host.number_of_particles *
                          sizeof(CUDA_particle_data),
                      hipMemcpyHostToDevice, stream[0]);
  }
}

/** setup and call kernel to copy particle forces to host
 */
void copy_forces_from_GPU(ParticleRange particles) {

  if (global_part_vars_host.communication_enabled == 1 &&
      global_part_vars_host.number_of_particles) {

    /** Copy result from device memory to host memory*/
    if (this_node == 0) {
      cuda_safe_mem(hipMemcpy(particle_forces_host, particle_forces_device,
                               3 * global_part_vars_host.number_of_particles *
                                   sizeof(float),
                               hipMemcpyDeviceToHost));
#ifdef ROTATION
      cuda_safe_mem(hipMemcpy(particle_torques_host, particle_torques_device,
                               global_part_vars_host.number_of_particles * 3 *
                                   sizeof(float),
                               hipMemcpyDeviceToHost));
#endif
#ifdef SHANCHEN
      cuda_safe_mem(hipMemcpy(fluid_composition_host, fluid_composition_device,
                               global_part_vars_host.number_of_particles *
                                   sizeof(CUDA_fluid_composition),
                               hipMemcpyDeviceToHost));
#endif

      /** values for the particle kernel */
      int threads_per_block_particles = 64;
      int blocks_per_grid_particles_y = 4;
      int blocks_per_grid_particles_x =
          (global_part_vars_host.number_of_particles +
           threads_per_block_particles * blocks_per_grid_particles_y - 1) /
          (threads_per_block_particles * blocks_per_grid_particles_y);
      dim3 dim_grid_particles = make_uint3(blocks_per_grid_particles_x,
                                           blocks_per_grid_particles_y, 1);

      /** reset part forces with zero*/

      KERNELCALL(reset_particle_force, dim_grid_particles,
                 threads_per_block_particles,
                 (particle_forces_device, particle_torques_device));
      hipDeviceSynchronize();
    }

    cuda_mpi_send_forces(particles, particle_forces_host,
                         particle_torques_host);
#ifdef SHANCHEN
    cuda_mpi_send_composition(particles, fluid_composition_host);
#endif
  }
}

#if defined(ENGINE) && defined(LB_GPU)
// setup and call kernel to copy v_cs to host
void copy_v_cs_from_GPU(ParticleRange particles) {
  if (global_part_vars_host.communication_enabled == 1 &&
      global_part_vars_host.number_of_particles) {
    // Copy result from device memory to host memory
    if (this_node == 0) {
      cuda_safe_mem(hipMemcpy2D(
          host_v_cs, sizeof(CUDA_v_cs), particle_data_device,
          sizeof(CUDA_particle_data), sizeof(CUDA_v_cs),
          global_part_vars_host.number_of_particles, hipMemcpyDeviceToHost));
    }
    cuda_mpi_send_v_cs(particles, host_v_cs);
  }
}
#endif

void clear_energy_on_GPU() {
  if (!global_part_vars_host.communication_enabled)
    // || !global_part_vars_host.number_of_particles )
    return;
  if (energy_device == nullptr)
    cuda_safe_mem(hipMalloc((void **)&energy_device, sizeof(CUDA_energy)));
  cuda_safe_mem(hipMemset(energy_device, 0, sizeof(CUDA_energy)));
}

void copy_energy_from_GPU() {
  if (!global_part_vars_host.communication_enabled ||
      !global_part_vars_host.number_of_particles)
    return;
  cuda_safe_mem(hipMemcpy(&energy_host, energy_device, sizeof(CUDA_energy),
                           hipMemcpyDeviceToHost));
  copy_CUDA_energy_to_energy(energy_host);
}

/** Generic copy functions from an to device **/

void cuda_copy_to_device(void *host_data, void *device_data, size_t n) {
  cuda_safe_mem(hipMemcpy(host_data, device_data, n, hipMemcpyHostToDevice));
}

void cuda_copy_to_host(void *host_device, void *device_host, size_t n) {
  cuda_safe_mem(
      hipMemcpy(host_device, device_host, n, hipMemcpyDeviceToHost));
}
