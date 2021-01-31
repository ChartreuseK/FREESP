FREESP and FREESPT -- Chartreuse 2021

Pre-assembled COM files can be found in the releases section!

FREESP 
-----------------

Calculates the free space on a FAT 16 disk very fast. 
On XT Class systems with large FAT 16 hard disks the initial DIR 
command can take upwards of 15-30 seconds to complete, this is due to 
the slow method that DOS uses for calculating free space on the hard
disk.  However once DOS has calculated this value it stores a cache of 
it which it keeps updated unless an application does raw disk accesses
such as CHKDSK.  This means that every subsequent DIR will take no time
to display free space.  This program is designed to quickly calculate 
the free space on the disk by reading through the FAT and counting up
the used clusters then calculating the total number of clusters on the 
disk and subtracting to get the number of free clusters.  Once 
calculated this value is stored into the Disk Parameter Block from DOS
in the field storing the free clusters which DIR uses for calculating 
free space.  With a 2GB FAT 16 partiton on a CF card in an XTIDE 
on my Turbo XT (running at 4.77MHz) this program takes <2s to complete
while the initial DIR call takes 25s. 

This program should run on any PC or compatible with DOS 4.0 or later
it has only been tested on MS-DOS 6.22 and 5.0. This program should be 
unneeded on DOS 3.2 and earlier as DIR does not perform a free space 
calculation, as well these versions also use FAT12 (or FAT16 <32MB) 
for disks which DOS keeps more metadata in memory and will avoid 
the slowdown.  It requires 66kB of free memory to run, but once 
complete does not use any, it is not a TSR.

Usage
------------

FREESP <A-Z>

Example:
FREESP C

This will pre-calculate free space on the C partition. I recommend
putting this program into your AUTOEXEC.BAT for each partition on your
system. If you are using 4DOS then you'll want to do this as 4DOS will
perform the free-space calculation before the running of a command
when it has to search the PATH.

Assembling
--------------
This program was created to assemble under Borland Turbo Assembler 2.01
with Borland Turbo Link 2.0

TASM FREESP.ASM
TLINK /T FREESP.OBJ

This will produce FREESP.COM


FREESPT
-----------------

This program is a TSR version of FREESP. It intercepts calls to DOS int 21h/36h
(Get Disk Space) which returns the amouint of free disk space.  The TSR checks 
if the request is for one of the drives specified, and if that drive currently
has an unknown number of free clusters. If so then it will quickly run and 
populate the number of free clusters before passing the call to the original 
handler. This version is ever so slightly slower than FREESP as it only uses a
512 byte sector buffer rather than loading 64kB of the FAT in at a time. But is 
still and order of magnitude faster than DOS's built in method.

As with FREESP this program should run on any PC or compatible running DOS 4.0
or later, but has only been tested on DOS 6.22.

The TSR uses 1,264 bytes of memory when running.

Usage
----------------

FREESPT <DRIVELIST>

DRIVELIST consists of a sequence of drive letters to monitor, and can consist 
of a maximum of 18 drives. These drives must be FAT16 filesystems.

Example:
FREESPT CDEF



Assembling
--------------------
This program was created to assemble under Borland Turbo Assembler 2.01
with Borland Turbo Link 2.0

TASM FREESPT.ASM
TLINK /T FREESPT.OBJ

This will produce FREESPT.COM

