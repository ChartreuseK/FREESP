; FREESP.ASM -- Chartreuse 2021
;
; Assembles with TASM 2.01 and TLINK 2.0, should work on other versions
;  TASM FREESP.ASM
;  TLINK /T FREESP.OBJ
;
;  Calculate free space on FAT16 disk as fast as possible
;  Read in the partition information to get location of
;  FAT. Read in FAT, scan for non-free (!= 0000) clusters,
;  calculate total clusters in volume, and subtract to get
;  the number of free clusters.
;  Finally store the value in the MSDOS DPB for the volume
;------------------------------------------------------------
	.model tiny
	.code
	LOCALS @@
	ORG 100h
start:
	lea sp, stacktop
	; Check if we have enough memory to load the entire 128kB
	; FAT at once
	mov bx, WORD PTR [ds:02h]	; Read in segment after our allocation
	mov ax, cs
	sub bx, ax		; # of segments we've been allocated
	cmp bx, ((64+2)*64)	; We need at least 64kB + ~2kB for prog
	jb  @@nomem
	; Compute segment for the buffer
	add ax, 2*64		; Allocate 2kB for our main program and data
				; Giving us the segment pointer for our 64k
				; buffer
	mov WORD PTR [fatseg], ax	; Save segment
	jmp @@ahead

@@nomem:
	mov ah,09h              ; Insufficient memory error, abort
	lea dx, insufmem
	int 21h
	int 20h
@@unknowndisk:
	mov ah, 09h		; Filesystem doesn't match expectations
	lea dx, diskerr		; abort
	int 21h
	int 20h
@@usage:
	mov ah, 09h		; Invalid parameter
	lea dx, usagestr
	int 21h
	int 20h

@@ahead:
	mov al, BYTE PTR [ds:82h] ; First character of parameter
	and al, 0DFh		; Convert to uppercase
	cmp al, 'A'
	jb @@usage
	cmp al, 'Z'
	ja @@usage

	sub al, 'A'		; Convert to drive number
	mov BYTE PTR [drv], al

	;---------------------------------
	; Read in boot sector for partition
	; Setup abs disk struct
	lea bx, absdisk
	mov WORD PTR [bx+0], 0	; Logical sector (low)
	mov WORD PTR [bx+2], 0	; Logical sector (high)
	mov WORD PTR [bx+4], 1	; # of sectors to read
	mov WORD PTR [bx+6], OFFSET bootseg
	mov ax, ds
	mov WORD PTR [bx+8], ax	; Address (FAR) to read to

	mov al, BYTE PTR [drv]	; Drive #
	mov cx, 0FFFFh	; Large disk, use AbsDiskIORec Struct
	mov dx, 0	; Beginning sector
	int 25h		; Absolute disk read
	pop dx		; Remove leftover word from stack from int25h
	jnc @@ahead2
	jmp readfail
@@ahead2:
	; We've now got the partition boot sector
	; Figure out which sector the FAT is at
	lea si, bootseg
	cmp WORD PTR [si+0Bh], 512	; Make sure this is 512 bytes/sector
	jne @@unknowndisk
	cmp WORD PTR [si+039h], 3631h	; Check that Filesystem type is FAT16
	jne @@unknowndisk
	; Assume we're looking at a FAT16 filesystem now

	mov ax, WORD PTR [si+16h]	; # of sectors per FAT
	cmp ax, 100h   		; More than 65536 clusters, not FAT16
	ja  @@unknowndisk

	; int 25h will not read more than 64kB (filling the segment
	;  of the far pointer passed). If # clusters is > 128 (128*512=64kB)
	;  then we need to do multiple reads. And for any decently sized
	;  disk it will be 256. (2x 64kB reads)

	mov bx, WORD PTR [si+0Eh] ; start of FAT

	cmp ax, 128
	jbe @@second		; If <=128 total then no need to do 2 reads
	push bx			; preserve start sector

	mov ax, 128
	push ax			; sectcount
	push bx			; startsect
	call getUsedClust	; getUsedClust(resvsect, 128)
	add sp, 4
	add WORD PTR [usedclust], ax	; # of used custers so far
	pop bx			; restort start sector
	add bx, 128		; start sector for remaining
	mov ax, WORD PTR [si+16h]
	sub ax, 128		; sectcount for remaining
@@second:
	push ax			; sectcount
	push bx			; startsect
	call getUsedClust
	add sp, 4
	add WORD PTR [usedclust], ax	; # of used clusters
	sub WORD PTR [usedclust], 2	; First two entries are used
					; to store the FAT signature
					; Don't count them.
	; We've got the number of used clusters
	; Get total clusters
	; Can't use int21h:1Ch since that runs the slow drive space
	; calculator for some reason
	; Total clusters =
	;   total sectors - hidden sectors - num fats * sectors per fat
	;  -------------------------------------------------------------
	;                      sectors per cluster
	; This will involve 32-bit maths
	xor dx,dx
	mov ax, WORD PTR [si+13h]	; Number of sectors (small)
	and ax,ax
	jne @@small		; If not 0 then word sized # of sectors
				; (Why are you using this tool for that...)
	mov ax, WORD PTR [si+20h]  	; Number of sectors (large-low word)
	mov dx, WORD PTR [si+22h]  	; (high word)
@@small:
	; DX:AX contains 32-bit total number of sectors
	mov bx, WORD PTR [si+1Ch]  	; # of hidden sectors
	sub ax, bx			; Subtract from total
	sbb dx, 0
	mov cl, BYTE PTR [si+10h] 	; # of FATs
	xor ch, ch
	mov bx, WORD PTR [si+16h]	; Sectors per FAT
@@fats:
	sub ax, bx			; sectors per FAT
	sbb dx, 0
	loop @@fats
	; DX:AX is now the number of available sectors
	; Convert to clusters
	mov bl, BYTE PTR [si+0Dh]	; Sectors per cluster
					; Guaranteed to be power of 2
@@sectclust:
	shr bl, 1
	jc @@found			; Found our power of 2 stop dividing
	shr dx, 1
	rcr ax, 1			; Divide DX:AX by 2
	jmp @@sectclust
@@found:
	; DX:AX now contains available clusters. Since FAT16 must be less
	; than 65525 clusters our result is in AX

	sub ax, WORD PTR [usedclust]	; AX = available clusters

	push ds
	push ax
	; Now we change the dos data structure
	mov ah, 32h		; Get Drive Parameter Block
	mov dl, BYTE PTR [drv]	; Get drive ID
	inc dl			; Drive # is offset by 1 compared with 25h
	int 21h
	; DS:BX now points straight to the appropriate data structure
	; For DOS 4-6 offset 1F contains a word with the # of free clusters
	; on drive, with FFFFh if unknown
	pop ax
	mov WORD PTR [bx+1Fh], ax	; Update free clusters
	pop ds

	int 20h                         ; Exit
	;-------------------------------------

readfail:
	mov ah, 09h
	lea dx, readfailstr
	int 21h
	int 20h

;------------------------------------------------
; word getUsedClust(word startsect, byte sectcount)
; startsect must be less than 65536 (fit in a word)
; (FAT should be in that area)
; sectcount must be 128 or less
getUsedClust PROC
	ARG startsect:WORD, sectcount:BYTE
	push bp
	mov bp, sp
	push di
	push si

	lea bx, absdisk
	mov ax, [startsect]
	mov WORD PTR [bx+0], ax ; Start sector (low word)
	xor ax, ax
	mov WORD PTR [bx+2], ax ; (high word)
	mov al, [sectcount]
	mov WORD PTR [bx+4], ax ; # of sectors to read
	mov WORD PTR [bx+6], 0	; offset of address to load to
	mov ax, WORD PTR [fatseg]
	mov WORD PTR [bx+8], ax ; Segment of address to load to

	mov al, BYTE PTR [drv]	; Drive #
	mov cx, 0FFFFh		; Use AbsDiskIORec
	mov dx, 0		; Beginning sector
	int 25h
	pop dx			; Fix stack
	jc readfail

	; Turn # sectors into number of entries to check
	xor cl, cl
	mov ch, [sectcount]	; sectcount * 256 (words per sector)
	mov ax, WORD PTR [fatseg]
	mov es, ax
	xor di, di
	xor bx, bx		; # of non-free sectors
	xor ax, ax		; 0 indicates free sector
@@scan:
	repe scasw		; Scan till we hit a non-free sector
	; We've hit a non-free sector, or are out of sectors to check
	jcxz @@done		; Done checking all entries
	inc bx			; Sector must not be free, count and
	jmp @@scan		; contiue
@@done:
	je @@nofix		; If NE then we didn't count the last used
	inc bx			; entry. Fix off by 1 error
@@nofix:
	mov ax, bx		; # of non-free sectors
	pop si
	pop di
	pop bp
	ret
getUsedClust ENDP

	.data
usedclust:
	DW 0		; # of non-free clusters
fatseg: DW 0		; Segment to contain our 128kB buffer
drv: 	DB 0		; Drive #
insufmem:
	DB "Insufficient memory.",10,13,"$"
diskerr:
	DB "Unknown disk type.",10,13,"$"
endstr: DB " Bytes available.",10,13,"$"
usagestr:
	DB "usage: FREESP <A-Z>",10,13
	DB " Precalculate free space on FAT16 filesystem fast.",10,13
	DB " Version 0.1",10,13,"$"
readfailstr:
	DB "Error reading from disk.",10,13,"$"
absdisk:
	DB 10 dup(?)	; AbsDiskIORec struct
bootseg:
	DB 512 dup(?)
; Stack
	DW 32 dup(?)
stacktop:
	end start
