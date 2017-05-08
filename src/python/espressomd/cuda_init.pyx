#
# Copyright (C) 2013,2014,2015,2016 The ESPResSo project
#
# This file is part of ESPResSo.
#
# ESPResSo is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# ESPResSo is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
from __future__ import print_function, absolute_import
include "myconfig.pxi"
from . cimport cuda_init

cdef class CudaInitHandle:
    def __init__(self):
        IF CUDA != 1:
            raise Exception("Cuda is not compiled in")

    property device:
        """cuda device to use

        :setter: Specify which device to use

        :getter: Returns the currently selected Cuda device id

        :type: int"""

        IF CUDA == 1:
            def __set__(self, int _dev):
                """
                Specify which device to use.

                Parameters
                ----------

                'dev':  integer
                    Set the device id of the graphics card to use.

                """
                if cuda_set_device(_dev):
                    raise Exception("cuda device set error")

            def __get__(self):
                """
                Get the id of the currently set device
                """
                dev = cuda_get_device()
                if dev == -1:
                    raise Exception("cuda device get error")
                return dev

    def list_devices(self):
        IF CUDA == 1:
            cdef char gpu_name_buffer[4+64]
            devices = dict()
            for i in range(cuda_get_n_gpus()):
                cuda_get_gpu_name(i, gpu_name_buffer)
                devices[i] = gpu_name_buffer
            return devices
#        print(cuda_get_n_gpus())


    # property device_list:
    #   IF CUDA == 1:
    #     def __set__(self, int _dev):
    #       raise Exception("cuda device list is read only")
    #     def __get__(self):
    #       cdef int _p_devl
    #       cdef char _devname[4+64]
    #       if getdevicelist(&_p_devl, _devname):
    #         raise Exception("cuda devicelist error")
    #       return _devname
