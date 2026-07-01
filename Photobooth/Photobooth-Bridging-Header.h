//  Bridging header — exposes the libgphoto2 C API to Swift so NikonSource can
//  drive the camera over PTP. Requires `brew install libgphoto2` (headers +
//  dylibs under /opt/homebrew/opt/libgphoto2). See project.yml for the
//  HEADER/LIBRARY search paths and -lgphoto2 -lgphoto2_port link flags.
#import <gphoto2/gphoto2.h>
