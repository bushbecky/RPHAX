import os
import sys

# Path

os.system("mkdir -p PYNQ_files")
os.system("mkdir -p PYNQ_files/overlay")
os.system("cp ./src/rphax_harness_proj/rphax_harness_proj.runs/impl_1/design_1_wrapper.bit  ./PYNQ_files/overlay/rphax_harness.bit")
os.system("cp ./src/rphax_harness_proj/rphax_harness_proj.gen/sources_1/bd/design_1/hw_handoff/design_1_bd.tcl ./PYNQ_files/overlay/rphax_harness.tcl")
os.system("cp ./src/rphax_harness_proj/rphax_harness_proj.gen/sources_1/bd/design_1/hw_handoff/design_1.hwh ./PYNQ_files/overlay/rphax_harness.hwh")
