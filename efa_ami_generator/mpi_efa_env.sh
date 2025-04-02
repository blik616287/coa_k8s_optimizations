
# OpenMPI and EFA binary paths
export PATH=$PATH:/opt/amazon/openmpi5/bin:/opt/amazon/efa/bin
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/opt/amazon/openmpi5/lib:/opt/amazon/efa/lib64

# Modules initialization if not already present
if [ -f /usr/share/Modules/init/bash ]; then
    source /usr/share/Modules/init/bash
fi

# Load OpenMPI module
MODULEPATH=/opt/amazon/modules/modulefiles:/usr/share/Modules/modulefiles:/etc/modulefiles
MODULESHOME=/usr/share/Modules
if command -v module &> /dev/null; then
    module load openmpi5
fi
