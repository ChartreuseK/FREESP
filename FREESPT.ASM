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

	CR			EQU		13
	LF			EQU		10

; We can overwrite the FCBs and parameters in the PSP, starting at 5Ch
; Giving us 164 bytes for this table. Or 18 entries/partitions at max
; If you've got 19 large FAT16 partitions in your XT, god help you.
	numdrives	EQU		5Ch		; BYTE - # of drives we're monitoring
	drvtbl		EQU		5Dh		; 9 BYTE per - information needed for each drive
; Runs till offset 100h
	ENTSIZE		EQU		9

; Entry struct:
;  BYTE - DRIVE #
;  WORD - SECTORS PER FAT
;  WORD - FAT SECTOR
;  FAR PTR (DWORD) - DPB CLUST PTR


	ORG 100h
start:
	jmp		init
myid:			db	"FS"
oldint21h:		dd	0
callerax:		dw	0
callerss:		dw	0
callersp:		dw	0
usedclust:		dw	0					; # of non-free clusters
absdisk:		db	10	dup(?)			; AbsDiskIORec struct
bootsect:		db	512	dup(?)
				dw	32	dup(?)			; Stack
stacktop:

even									; Keep the interrupt handler WORD aligned
inthandler:
	pushf								; Preserve flags
	cmp		ah, 36h						; Calculate disk free space
	je		@@handle
	cmp		ah, 1Ch						; Get allocation data for specified drive
	je		@@handle
	cmp		ah, 1Bh						; 1Bh requires us to get the 'current' drive, as do 36 and 1C w/DL=0
	je		@@handle
	; Some other int 21h function, we don't care
	popf
	jmp		DWORD PTR cs:[oldint21h]
@@handle:
	mov		cs:[callerax], ax
	mov		cs:[callersp], sp
	mov		cs:[callerss], ss
	mov		ax, cs
	mov		ss, ax
	mov		sp, OFFSET stacktop
	push	ds
	mov		ds, ax						; ds = ss = cs
	; We now have a stack and ds setup
	push	dx							; Save dx first

	cmp		BYTE PTR ds:[callerax+1], 1Bh
	je		@@getdefault
	test	dl, dl						; Check if drive # is default
	jnz		@@scan
@@getdefault:
	mov		ah, 19h
	int		21h							; 21h/19h = Get default disk drive
	inc		ax
	mov		dl, al						; Move into dl to be consistent with others
@@scan:
	; Scan through our drive table to see if we care for this drive
	; and if it's unknown
	push	si
	push	cx
	xor		ch, ch
	mov		cl, ds:[numdrives]
	mov		si, drvtbl
@@scanloop:
	mov		al, ds:[si]
	inc		ax
	cmp		al, dl						; Does the drive match this call?
	je		@@found
	add		si, 9						; Next entry
	loop	@@scanloop
	; Not a drive we care about
	pop		cx
	pop		si
	jmp		SHORT exit1
@@found:
	; The drive requested is one we're monitoring
	; Check if free clusters == FFFFh
	push	ds
	push	bx
	; Check if current value is unknown 0FFFFh
	lds		bx, ds:[si+5]
	cmp		WORD PTR [bx], 0FFFFh
	pop		bx
	pop		ds
	je		recalc						; If so then we need to recalculate
	; Otherwise just pass through to the int 21h handler
	pop		cx
	pop		si
	jmp		SHORT exit1
recalc:
	; cx, si still on stack from scan loop
	push	bx							; Preserve other registers
	push	di
	push	bp
	push	es
	; We can now run our recalc code
	; We are the int 21h handler so don't run `int 21h`
	; Instead do: `call doint21` if needed
	call	docalc
exit2:
	; Return to caller's stack frame
	pop		es
	pop		bp
	pop		di
	pop		bx
	pop		cx
	pop		si
exit1:
	pop		dx
	mov		ax, ds:[callerax]
	pop		ds
	mov		ss, cs:[callerss]
	mov		sp, cs:[callersp]
	popf
	jmp		DWORD PTR cs:[oldint21h]

;doint21:
;	pushf
;	jmp		DWORD PTR cs:[oldint21h]	; tail call

	; Calculate free space
docalc:
	; DS:SI still points to entry in drvtbl
	mov		WORD PTR [usedclust], -2	; First two entries are used to store the FAT signature
	mov		cx, [si+1]					; sectperfat
	mov		bx, [si+3]					; fatsector
	push	si							; Preserve entry
@@fatloop:
	push	cx							; Preserve count
	push	bx							; Preserve start sector
	mov		al, [si]					; Drive #
	push	ax
	mov		ax, 1						; # of sectors
	push	ax
	push	bx							; start sector
	call	getUsedClust
	add		sp, 6
	add		[usedclust], ax				; # used so far
	pop		bx							; Restore start sector
	inc		bx							; # of sectors handled so far
	pop		cx
	loop	@@fatloop

	; We've got the number of used clusters
	; Get total clusters
	; Can't use int21h:1Ch since that runs the slow drive space
	; calculator for some reason
	; Re-Read in boot sector for partition
	; Setup abs disk struct
	mov		bx, OFFSET absdisk
	mov		[bx], cx					; Logical sector (low)
	mov		[bx+2], cx					; Logical sector (high)
	mov		WORD PTR [bx+4], 1			; # of sectors to read
	mov		WORD PTR [bx+6], OFFSET bootsect
	mov		[bx+8], ds					; Address (FAR) to read to
	mov		al, [si]					; Drive #
	dec		cx							; Large disk, use AbsDiskIORec Struct
	xor		dx, dx						; Beginning sector
	int		25h							; Absolute disk read
	pop		dx							; Remove leftover word from stack from int25h
	jnc		@@ahead3
	; Read failed, abort/return
	pop		si
	ret
@@ahead3:
	call	getTotalClusters
	sub		ax, [usedclust]				; AX = available clusters

	pop		si
	les		bx, [si+5]
	mov		es:[bx], ax					; Update free clusters
	ret

getTotalClusters PROC
	mov		si, OFFSET bootsect
	; Total clusters =
	;   total sectors - hidden sectors - num fats * sectors per fat
	;  -------------------------------------------------------------
	;                      sectors per cluster
	; This will involve 32-bit maths
	;---------------------------------
	xor		ax, ax
	cwd
	or		ax, [si+13h]				; Number of sectors (small)
	jnz		@@small						; If not 0 then word sized # of sectors
										; (Why are you using this tool for that...)
	mov		ax, [si+20h]				; Number of sectors (large-low word)
	mov		dx, [si+22h]				; (high word)
@@small:
	; DX:AX contains 32-bit total number of sectors
	xor		cx, cx
	sub		ax, [si+1Ch]				; Subtract # of hidden sectors from total
	sbb		dx, cx
	mov		cl, [si+10h]				; # of FATs
@@fats:
	sub		ax, [si+16h]				; Sectors per FAT
	sbb		dx, 0
	loop	@@fats
	; DX:AX is now the number of available sectors
	; Convert to clusters
	mov		cl, [si+0Dh]				; Sectors per cluster
										; Guaranteed to be power of 2
@@sectclust:
	shr		cl, 1
	jc		@@found						; Found our power of 2 stop dividing
	shr		dx, 1
	rcr		ax, 1						; Divide DX:AX by 2
	jmp		SHORT @@sectclust
@@found:
	; DX:AX now contains available clusters. Since FAT16 must be less
	; than 65525 clusters our result is in AX
	ret
getTotalClusters ENDP


;------------------------------------------------
; word getUsedClust(word startsect, byte sectcount)
; startsect must be less than 65536 (fit in a word)
; (FAT should be in that area)
; sectcount must be 128 or less
getUsedClust PROC
	ARG startsect:WORD, sectcount:BYTE, drive:BYTE

	push	bp
	mov		bp, sp
	push	di
	push	si

	mov		bx, OFFSET absdisk
	mov		ax, [startsect]
	mov		[bx], ax					; Start sector (low word)
	xor		ax, ax
	cwd									; Beginning sector
	mov		[bx+2], ax					; (high word)
	mov		al, [sectcount]
	mov		[bx+4], ax					; # of sectors to read

	mov		WORD PTR [bx+6], OFFSET bootsect
	mov		[bx+8], ds

	mov		al, [drive]					; Drive #
	mov		cx, 0FFFFh					; Use AbsDiskIORec
	int		25h
	pop		dx							; Fix stack
	sbb		ax, ax						; 0 indicates free sector, -1 = Fail
	jc		@@fail

	; Turn # sectors into number of entries to check
	mov		cx, ds
	mov		es, cx
	mov		cl, al
	mov		ch, [sectcount]				; sectcount * 256 (words per sector)
	mov		di, OFFSET bootsect
	mov		bx, ax						; # of non-free sectors
@@scan:
	repe	scasw						; Scan till we hit a non-free sector
	; We've hit a non-free sector, or are out of sectors to check
	jcxz	@@done						; Done checking all entries
	inc		bx							; Sector must not be free, count and
	jmp		SHORT @@scan				; continue
@@done:
	je		@@nofix						; If NE then we didn't count the last used
	inc		bx							; entry. Fix off by 1 error
@@nofix:
	xchg	bx, ax						; # of non-free sectors to AX
@@fail:
	pop		si
	pop		di
	pop		bp
	ret
getUsedClust ENDP


; ---------------------------------------------------
; Split between TSR memory, and initialization memory
; ---------------------------------------------------
init:
	mov		sp, OFFSET stacktop
	call	parsecmd					; Parse command line
	; We've got a list of drives in tempdrives to setup, al is the #
	mov		ds:[numdrives], al
	; Initialize table for each drive
	mov		si, OFFSET tempdrives
	mov		di, drvtbl					; Pointer to start of table
	xor		cl, cl						; Index #
	xor		ax, ax
@@initloop:
	push	cx							; Preserve CX
	push	di							; Table entry pointer
	lodsb								; Get drive #
	push	ax
	call	initdrive					; initdrive(drive #, index)
	add		sp, 4
	pop		cx
	add		di, ENTSIZE					; Next entry
	inc		cl
	cmp		cl, ds:[numdrives]
	jne		@@initloop

	; Free our environment to save space
	mov		es, ds:[2Ch]				; Environment block
	mov		ah, 49h
	int		21h							; Free environment block

	; Install our TSR
	mov		ax, 3521h					; Get int 21h vector
	int		21h							; from int 21h itself :)
	; ES:BX contains the vector
	mov		[oldint21h], bx
	mov		[oldint21h+2], es

	; Now install our new vector (DS:DX)
	mov		dx, OFFSET inthandler
	mov		ah, 25h						; Install over int 21h
	int		21h

	; Now we terminate and stay resident
	mov		cl, 4
	mov		dx, OFFSET init+15			; How much do we need to keep
	shr		dx, cl						; # of paragraphs
	mov		ax, 3100h					; TSR
	int		21h							; Hopefully we haven't broken int 21h here...

;------------------------------------------------------
; BYTE parsecmd()
;  Parses the command line arguments and fills up the tempdrives array
;  Aborts and shows usage if error encountered
;  Returns number of drives specified
parsecmd PROC
	push	si
	push	di

	push	ds
	pop		es

	mov		di, 81h						; First character of cmd line ds:di
	; Skip any initial spaces
	mov		al, 20h						; Space
	mov		cx, 127						; Max characters
	repe	scasb
	dec		di							; scasb will increment over the first non-match

	mov		si, di

	lodsb
	cmp		al, CR						; Were we run with no arguments?
	je		@@usage
	dec		si							; Point back at same argument for first entry

	xor		cl, cl						; Count of drives read
	; Loop over characters adding to array
@@argloop:
	lodsb
	cmp		al, CR						; End of arguments
	je		@@doneargs
	cmp		cl, MAXDRIVES
	je		@@usage						; Too many drives
	and		al, 0DFh					; Convert to uppercase
	cmp		al, 'Z'
	ja		@@usage						; Non-letter character
	sub		al, 'A'						; Convert to drive number
	jb		@@usage						; Non-letter character
	; Scan temp drives to find spot, or repetition
	xchg	di, si						; save cmd offset in di
	mov		si, OFFSET tempdrives
	mov		bl, al
@@insert:
	lodsb
	cmp		al, bl
	je		@@usage						; Repetition found, error
	cmp		al, 0FFh
	jne		@@insert					; Go until we find a spot
	dec		si
	xchg	di, si						; cmd offset in si, tempdrives offset in di
	mov		al, bl
	stosb								; Store into drive list
	inc		cx							; Count of drives read so far
	jmp		SHORT @@argloop
@@doneargs:
	; We've handled all drives specified. tempdrives contains the list
	; of drive #'s to setup
	jcxz	@@usage						; One last check to make sure we got a drive
	xchg	cx, ax						; AX contains number of drives listed
	pop		di
	pop		si
	ret
@@usage:
	mov		ah, 09h						; Invalid parameter
	mov		dx, OFFSET usagestr
	int		21h
	int		20h
parsecmd ENDP


;----------------------------------------
; void initdrive(BYTE drive, WORD tblptr)
; Initialize given drive and populate drive table entry
initdrive PROC
	ARG drive:BYTE, tblptr:WORD
	push	bp
	mov		bp, sp
	push	di
	push	si

	push	ds
	pop		es
	; Store drive number first
	mov		di, [tblptr]
	mov		al, [drive]
	stosb

	; Read in boot sector for partition
	; Setup abs disk struct
	xor		dx, dx						; Beginning sector
	mov		bx, OFFSET absdisk
	mov		[bx], dx					; Logical sector (low)
	mov		[bx+2], dx					; Logical sector (high)
	mov		WORD PTR [bx+4], 1			; # of sectors to read
	mov		WORD PTR [bx+6], OFFSET bootsect
	mov		[bx+8], ds					; Address (FAR) to read to

	mov		al, [drive]					; Drive #
	mov		cx, 0FFFFh					; Large disk, use AbsDiskIORec Struct
	int		25h							; Absolute disk read
	pop		dx							; Remove leftover word from stack from int25h
	jnc		@@ahead2
	mov		ah, 09h
	mov		dx, OFFSET readfailstr
	int		21h
	int		20h

@@ahead2:
	; We've now got the partition boot sector
	; Figure out which sector the FAT is at
	cmp		WORD PTR [OFFSET bootsect+0Bh], 512	; Make sure this is 512 bytes/sector
	jne		@@unknowndisk
	; Check that the filesystem is FAT16 by looking at the cluster count
	call	getTotalClusters
	test	dx, dx
	jnz		@@unknowndisk				; Total Clusters >= 65536 = FAT32
	cmp		ax, 65524
	ja		@@unknowndisk				; >= 65525  = FAT32
	cmp		ax, 4085
	jb		@@unknowndisk				; < 4085 = FAT12

	; Assume we're looking at a FAT16 filesystem now
	mov		ax, [si+16h]				; # of sectors per FAT
	cmp		ax, 100h					; More than 65536 clusters, not FAT16
	ja		@@unknowndisk

	stosw								; Sectors per fat
	mov		ax, [si+0Eh]				; start of FAT
	stosw								; Fat start sector

	push	ds
	; Now we change the dos data structure
	mov		ah, 32h						; Get Drive Parameter Block
	mov		dl, [drive]					; Get drive ID
	inc		dl							; Drive # is offset by 1 compared with 25h
	int		21h
	; DS:BX now points straight to the appropriate data structure
	; For DOS 4-6 offset 1F contains a word with the # of free clusters
	; on drive, with FFFFh if unknown
	add		bx, 1Fh						; Offset to # of free clusters
	; Save pointer to free cluster value
	xchg	bx, ax
	stosw
	mov		ax, ds
	stosw
	pop		ds

	; Drive has been initialized
	pop		si
	pop		di
	pop		bp
	ret
@@unknowndisk:
	mov		ah, 09h						; Filesystem doesn't match expectations
	mov		dx, OFFSET diskerr			; abort
	int		21h
	int		20h
initdrive ENDP


; Temporary list of drives since we'll overwrite our arguments
	MAXDRIVES	EQU		18				; Maximum drives supported
tempdrives:
	db	MAXDRIVES+1 DUP (0FFh)

usagestr:
	db	"usage: FREESPT <DRIVELIST>",CR,LF
	db	" TSR to monitor when disk free space available is unknown and",CR,LF
	db	" calculates free space on FAT16 filesystem fast.",CR,LF
	db	" DRIVELIST consists of a sequence of drive letters to monitor",CR,LF
	db	" DRIVELIST can contain a maximum of 18 drives",CR,LF
	db	" eg. ",CR,LF
	db	"   FREESPT CDEF",CR,LF,LF
	db	" Version 0.5",CR,LF,"$"
diskerr:
	db	"Unknown disk type.",CR,LF,"$"
readfailstr:
	db	"Error reading from disk.",CR,LF,"$"

		end start
