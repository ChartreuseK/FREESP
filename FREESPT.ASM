; FREESPT.ASM -- Chartreuse 2021
;
; Small memory usage version, only uses one 512 byte buffer, slightly slower
; TSR version. Hooks int 21h/36h which performs a free space calculation
; if the cached value is invalid. (FFFFh). And will run itself instead
; before allowing the call
;
; Assembles with TASM 2.01 and TLINK 2.0, should work on other versions
;  TASM FREESPT.ASM
;  TLINK /T FREESPT.OBJ
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

; We can overwrite the FCBs and parameters in the PSP, starting at 5Ch
; Giving us 164 bytes for this table. Or 18 entries/partitions at max
; If you've got 19 large FAT16 partitions in your XT, god help you.
numdrives EQU 5Ch	; BYTE - # of drives we're monitoring
drvtbl	EQU 5Dh		; 9 BYTE per - information needed for each drive
; Runs till offset 100h
ENTSIZE EQU 9

; Entry struct:
;  BYTE - DRIVE #
;  WORD - SECTORS PER FAT
;  WORD - FAT SECTOR
;  FAR PTR (DWORD) - DPB CLUST PTR


	ORG 100h
start:
	jmp init
myid:	  DB "FS"
oldint21h: DD 0
callerax: DW 0
callerss: DW 0
callersp: DW 0
usedclust:
	DW 0		; # of non-free clusters
absdisk:
	DB 10 dup(?)	; AbsDiskIORec struct
bootseg:
	DB 512 dup(?)
; Stack
	DW 32 dup(?)
stacktop:


inthandler:
	pushf		; Preserve flags
	cmp ah, 36h	; Calculate disk free space
	je @@handle
	; Some other int 21h function, we don't care
	popf
	jmp DWORD PTR cs:[oldint21h]
@@handle:
	mov WORD PTR cs:[callerax], ax
	mov WORD PTR cs:[callersp], sp
	mov ax, ss
	mov WORD PTR cs:[callerss], ax
	mov ax, cs
	mov ss, ax
	mov sp, OFFSET stacktop
	push ds
	mov ds, ax			; ds = ss = cs
	; We now have a stack and ds setup

	; Scan through our drive table to see if we care for this drive
	; and if it's unknown
	push si
	push cx
	xor ch, ch
	mov cl, ds:[numdrives]
	mov si, drvtbl
@@scanloop:
	mov al, ds:[si]
	inc al
	cmp al, dl		; Does the drive match this call?
	je @@found
	add si, 9		; Next entry
	loop @@scanloop
	; Not a drive we care about
	pop cx
	pop si
	jmp exit1
@@found:
	; The drive requested is one we're monitoring
	; Check if free clusters == FFFFh
	push ds
	push bx
	; Check if current value is unknown 0FFFFh
	mov bx, WORD PTR cs:[si + 7]
	mov ds, bx
	mov bx, WORD PTR cs:[si + 5]
	cmp WORD PTR [bx], 0FFFFh
	je recalc	; If so then we need to recalculate
	; Otherwise just pass through to the int 21h handler
	pop bx
	pop ds
	pop cx
	pop si
	jmp exit1
recalc:
	pop bx
	pop ds
	; cx, si still on stack from scan loop

	push bx		; Preserve other registers
	push dx
	push di
	push bp
	push es
	; We can now run our recalc code
	; We are the int 21h handler so don't run `int 21h`
	; Instead do: `call doint21` if needed
	call docalc
exit2:
	; Return to caller's stack frame
	pop es
	pop bp
	pop di
	pop dx
	pop bx
	pop cx
	pop si
exit1:
	pop ds
	mov ax, WORD PTR cs:[callerss]
	mov ss, ax
	mov sp, WORD PTR cs:[callersp]
	mov ax, WORD PTR cs:[callerax]
	popf
	jmp DWORD PTR cs:[oldint21h]

doint21:
	pushf
	jmp DWORD PTR cs:[oldint21h] ; tail call

	; Calculate free space
docalc:
	; DS:SI still points to entry in drvtbl
	mov WORD PTR [usedclust], 0
	mov cx, WORD PTR [si + 1]	; sectperfat
	mov bx, WORD PTR [si + 3]    ; fatsector
	push si			; Preserve entry
@@fatloop:
	push cx			; Preserve count
	push bx			; Preserve start sector
	mov al, BYTE PTR [si + 0] ; Drive #
	push ax
	mov ax, 1		; # of sectors
	push ax
	push bx			; start sector
	call getUsedClust
	add sp, 6
	add WORD PTR [usedclust], ax ; # used so far
	pop bx			; Restore start sector
	add bx, 1		; # of sectors handled so far
	pop cx
	loop @@fatloop

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
	;---------------------------------
	; Re-Read in boot sector for partition
	; Setup abs disk struct
	lea bx, absdisk
	mov WORD PTR [bx+0], 0	; Logical sector (low)
	mov WORD PTR [bx+2], 0	; Logical sector (high)
	mov WORD PTR [bx+4], 1	; # of sectors to read
	mov WORD PTR [bx+6], OFFSET bootseg
	mov ax, ds
	mov WORD PTR [bx+8], ax	; Address (FAR) to read to
	mov al, BYTE PTR [si+0]	; Drive #
	mov cx, 0FFFFh	; Large disk, use AbsDiskIORec Struct
	mov dx, 0	; Beginning sector
	int 25h		; Absolute disk read
	pop dx		; Remove leftover word from stack from int25h

	jnc @@ahead3
	; Read failed, abort/return
	pop si
	ret
@@ahead3:
	lea si, bootseg
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

	pop si
	push ax
	mov ax, WORD PTR [si+7]		; dpbclust+2
	mov es,ax
	mov bx, WORD PTR [si+5]		; dpbclust
	pop ax
	mov WORD PTR es:[bx], ax	; Update free clusters
	ret

;------------------------------------------------
; word getUsedClust(word startsect, byte sectcount)
; startsect must be less than 65536 (fit in a word)
; (FAT should be in that area)
; sectcount must be 128 or less
getUsedClust PROC
	ARG startsect:WORD, sectcount:BYTE, drive:BYTE

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

	mov ax, ds
	mov WORD PTR [bx+6], OFFSET bootseg
	mov WORD PTR [bx+8], ax

	mov al, [drive]		; Drive #
	mov cx, 0FFFFh		; Use AbsDiskIORec
	mov dx, 0		; Beginning sector
	int 25h
	pop dx			; Fix stack
	jc @@fail

	; Turn # sectors into number of entries to check
	xor cl, cl
	mov ch, [sectcount]	; sectcount * 256 (words per sector)
	mov ax, ds
	mov es, ax
	lea di, bootseg
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
@@fail:
	mov ax, 0FFFFh		; Failed
	pop si
	pop di
	pop bp
	ret
getUsedClust ENDP





; ---------------------------------------------------
; Split between TSR memory, and initialization memory
; ---------------------------------------------------


init:
	lea sp, stacktop
	call parsecmd		; Parse command line
	; We've got a list of drives in tempdrives to setup, al is the #
	mov BYTE PTR ds:[numdrives], al
	; Initialize table for each drive
	mov si, OFFSET tempdrives
	mov di, drvtbl		; Pointer to start of table
	xor cl, cl		; Index #
	xor ax, ax
@@initloop:
	push cx			; Preserve cx
	 push di		; Table entry pointer
	 lodsb			; Get drive #
	 push ax
	 call initdrive		; initdrive(drive #, index)
	 add sp, 4
	pop cx
	add di, ENTSIZE		; Next entry
	inc cl
	cmp cl, BYTE PTR ds:[numdrives]
	jne @@initloop

	; Free our environment to save space
	mov ax, WORD PTR ds:[2Ch]	; Environment block
	mov es, ax
	mov ah, 49h
	int 21h			; Free environment block

	; Install our TSR
	mov ax, 3521h		; Get int 21h vector
	int 21h			; from int 21h itself :)
	; ES:BX contains the vector
	mov WORD PTR [oldint21h], bx
	mov WORD PTR [oldint21h+2], es

	; Now install our new vector
	mov ax, cs
	mov es, ax
	mov dx, OFFSET inthandler
	mov ax, 2521h		; Install over int 21h
	int 21h

	; Now we terminate and stay resident
	mov dx, OFFSET init	; How much do we need to keep
	add dx, 15		; Make sure we round upward in space
	shr dx, 1
	shr dx, 1
	shr dx, 1
	shr dx, 1		; # of paragraphs
	mov ax, 3100h		; TSR
	int 21h			; Hopefully we haven't broken int 21h here...

readfail:
	mov ah, 09h
	lea dx, readfailstr
	int 21h
	int 20h

;------------------------------------------------------
; BYTE parsecmd()
;  Parses the command line arguments and fills up the tempdrives array
;  Aborts and shows usage if error encountered
;  Returns number of drives specified
parsecmd PROC
	push si
	push di

	push ds
	pop es

	mov di, 81h		; First character of cmd line ds:di
	; Skip any initial spaces
	mov al, 20h		; Space
	mov cx, 127		; Max characters
	repe scasb
	dec di		; scasb will increment over the first non-match

	mov si, di

	lodsb
	cmp al, 0Dh		; Were we run with no arguments?
	je @@usage
	dec si			; Point back at same argument for first entry


	mov cl, 0		; Count of drives read
	; Loop over characters adding to array
@@argloop:
	lodsb
	cmp al, 0Dh             ; End of arguments
	je @@doneargs
	cmp cl, MAXDRIVES
	je @@usage		; Too many drives
	and al, 0DFh		; Convert to uppercase
	cmp al, 'A'
	jb @@usage		; Non-letter character
	cmp al, 'Z'
	ja @@usage		; Non-letter character
	sub al, 'A'		; Convert to drive number
	; Scan temp drives to find spot, or repetition
	xchg di, si		; save cmd offset in di
	mov si, OFFSET tempdrives
	mov bl, al
@@insert:
	lodsb
	cmp al, bl
	je @@usage		; Repetition found, error
	cmp al, 0FFh
	jne @@insert		; Go until we find a spot
	dec si
	xchg di, si		; cmd offset in si, tempdrives offset in di
	mov al, bl
	stosb			; Store into drive list
	inc cl			; Count of drives read so far
	jmp @@argloop
@@doneargs:
	; We've handled all drives specified. tempdrives contains the list
	; of drive #'s to setup
	and cl, cl
	je @@usage		; One last check to make sure we got a drive
	mov al, cl
	xor ah, ah		; AL (ax) contains number of drives listed
	pop di
	pop si
	ret
@@usage:
	mov ah, 09h		; Invalid parameter
	lea dx, usagestr
	int 21h
	int 20h
parsecmd ENDP



;----------------------------------------
; void initdrive(BYTE drive, WORD tblptr)
; Initialize given drive and populate drive table entry
initdrive PROC
	ARG drive:BYTE, tblptr:WORD
	push bp
	mov bp, sp
	push di
	push si

	push ds
	pop es
	; Store drive number first
	mov di, [tblptr]
	mov al, [drive]
	stosb

	; Read in boot sector for partition
	; Setup abs disk struct
	lea bx, absdisk
	mov WORD PTR [bx+0], 0	; Logical sector (low)
	mov WORD PTR [bx+2], 0	; Logical sector (high)
	mov WORD PTR [bx+4], 1	; # of sectors to read
	mov WORD PTR [bx+6], OFFSET bootseg
	mov ax, ds
	mov WORD PTR [bx+8], ax	; Address (FAR) to read to

	mov al, [drive]	; Drive #
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


	stosw			; Sectors per fat
	mov ax, WORD PTR [si+0Eh] ; start of FAT
	stosw			; Fat start sector

	push ds
	; Now we change the dos data structure
	mov ah, 32h		; Get Drive Parameter Block
	mov dl, [drive]		; Get drive ID
	inc dl			; Drive # is offset by 1 compared with 25h
	int 21h
	; DS:BX now points straight to the appropriate data structure
	; For DOS 4-6 offset 1F contains a word with the # of free clusters
	; on drive, with FFFFh if unknown
	add bx, 1Fh		; Offset to # of free clusters
	; Save pointer to free cluster value
	mov ax, bx
	stosw
	mov ax, ds
	stosw
	pop ds

	; Drive has been initialized
	pop si
	pop di
	pop bp
	ret
@@unknowndisk:
	mov ah, 09h		; Filesystem doesn't match expectations
	lea dx, diskerr		; abort
	int 21h
	int 20h
initdrive ENDP


; Temporary list of drives since we'll overwrite our arguments
MAXDRIVES EQU 18		; Maximum drives supported
tempdrives:
	DB MAXDRIVES+1 DUP (0FFh)

usagestr:
	DB "usage: FREESPT <DRIVELIST>",10,13
	DB " TSR to monitor when disk free space available is unknown and",10,13
	DB " calculates free space on FAT16 filesystem fast.",10,13
	DB " DRIVELIST consists of a sequence of drive letters to monitor",10,13
	DB " DRIVELIST can contain a maximum of 18 drives", 10,13
	DB " eg. ", 10,13
	DB "   FREESPT CDEF", 10,13,10,13
	DB " Version 0.2",10,13,"$"
diskerr:
	DB "Unknown disk type.",10,13,"$"
readfailstr:
	DB "Error reading from disk.",10,13,"$"

        end start
