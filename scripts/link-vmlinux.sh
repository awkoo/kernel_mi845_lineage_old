#!/bin/sh
#
# link vmlinux
#
# vmlinux is linked from the objects selected by $(KBUILD_VMLINUX_INIT) and
# $(KBUILD_VMLINUX_MAIN). Most are built-in.o files from top-level directories
# in the kernel tree, others are specified in arch/$(ARCH)/Makefile.
# Ordering when linking is important, and $(KBUILD_VMLINUX_INIT) must be first.
#
# vmlinux
#   ^
#   |
#   +-< $(KBUILD_VMLINUX_INIT)
#   |   +--< init/version.o + more
#   |
#   +--< $(KBUILD_VMLINUX_MAIN)
#   |    +--< drivers/built-in.a mm/built-in.a + more
#   |
#   +-< ${kallsymso} (see description in KALLSYMS section)
#
# vmlinux version (uname -v) cannot be updated during normal
# descending-into-subdirs phase since we do not yet know if we need to
# update vmlinux.
# Therefore this step is delayed until just before final link of vmlinux.
#
# System.map is generated to document addresses of all kernel symbols

# Error out on error
set -e

is_enabled() {
	grep -q "^$1=y" include/config/auto.conf
}

# Nice output in kbuild format
# Will be supressed by "make -s"
info()
{
	if [ "${quiet}" != "silent_" ]; then
		printf "  %-7s %s\n" ${1} ${2}
	fi
}

# Link of vmlinux
# ${1} - output file
# ${2} - optional extra .o files
vmlinux_link()
{
	local output=${1}
	local lds="${objtree}/${KBUILD_LDS}"

	# skip output file argument
	shift

	${LD} ${LDFLAGS} ${LDFLAGS_vmlinux} \
		-o ${output} \
		-T ${lds} \
		--whole-archive \
		${KBUILD_VMLINUX_OBJS} \
		--no-whole-archive \
		--start-group \
		${KBUILD_VMLINUX_LIBS} \
		--end-group \
		${@}
}

# Create ${2} .o file with all symbols from the ${1} object file
kallsyms()
{
	info KSYM ${2}
	local kallsymopt;

	if is_enabled CONFIG_HAVE_UNDERSCORE_SYMBOL_PREFIX; then
		kallsymopt="${kallsymopt} --symbol-prefix=_"
	fi

	if is_enabled CONFIG_KALLSYMS_ALL; then
		kallsymopt="${kallsymopt} --all-symbols"
	fi

	if is_enabled CONFIG_KALLSYMS_ABSOLUTE_PERCPU; then
		kallsymopt="${kallsymopt} --absolute-percpu"
	fi

	if is_enabled CONFIG_KALLSYMS_BASE_RELATIVE; then
		kallsymopt="${kallsymopt} --base-relative"
	fi

	local aflags="${KBUILD_AFLAGS} ${KBUILD_AFLAGS_KERNEL}               \
		      ${NOSTDINC_FLAGS} ${LINUXINCLUDE} ${KBUILD_CPPFLAGS}"

	local afile="`basename ${2} .o`.S"

	${NM} -n ${1} | scripts/kallsyms ${kallsymopt} > ${afile}
	${CC} ${aflags} -c -o ${2} ${afile}
}

# Create map file with all symbols from ${1}
# See mksymap for additional details
mksysmap()
{
	${CONFIG_SHELL} "${srctree}/scripts/mksysmap" ${1} ${2}
}

sortextable()
{
	${objtree}/scripts/sortextable ${1}
}

# Delete output files in case of error
cleanup()
{
	rm -f .old_version
	rm -f .tmp_System.map
	rm -f .tmp_kallsyms*
	rm -f .tmp_version
	rm -f .tmp_symversions
	rm -f .tmp_vmlinux*
	rm -f built-in.a
	rm -f System.map
	rm -f vmlinux
}

on_exit()
{
	if [ $? -ne 0 ]; then
		cleanup
	fi
}
trap on_exit EXIT

on_signals()
{
	exit 1
}
trap on_signals HUP INT QUIT TERM

#
#
# Use "make V=1" to debug this script
case "${KBUILD_VERBOSE}" in
*1*)
	set -x
	;;
esac

if [ "$1" = "clean" ]; then
	cleanup
	exit 0
fi

# final build of init/
${MAKE} -f "${srctree}/scripts/Makefile.build" obj=init

kallsymso=""
kallsyms_vmlinux=""
if is_enabled CONFIG_KALLSYMS; then

	# kallsyms support
	# Generate section listing all symbols and add it into vmlinux
	# It's a three step process:
	# 1)  Link .tmp_vmlinux1 so it has all symbols and sections,
	#     but __kallsyms is empty.
	#     Running kallsyms on that gives us .tmp_kallsyms1.o with
	#     the right size
	# 2)  Link .tmp_vmlinux2 so it now has a __kallsyms section of
	#     the right size, but due to the added section, some
	#     addresses have shifted.
	#     From here, we generate a correct .tmp_kallsyms2.o
	# 2a) We may use an extra pass as this has been necessary to
	#     woraround some alignment related bugs.
	#     KALLSYMS_EXTRA_PASS=1 is used to trigger this.
	# 3)  The correct ${kallsymso} is linked into the final vmlinux.
	#
	# a)  Verify that the System.map from vmlinux matches the map from
	#     ${kallsymso}.

	kallsymso=.tmp_kallsyms2.o
	kallsyms_vmlinux=.tmp_vmlinux2

	# step 1
	vmlinux_link .tmp_vmlinux1 ""
	kallsyms .tmp_vmlinux1 .tmp_kallsyms1.o

	# step 2
	vmlinux_link .tmp_vmlinux2 .tmp_kallsyms1.o
	kallsyms .tmp_vmlinux2 .tmp_kallsyms2.o

	# step 2a
	if [ -n "${KALLSYMS_EXTRA_PASS}" ]; then
		kallsymso=.tmp_kallsyms3.o
		kallsyms_vmlinux=.tmp_vmlinux3

		vmlinux_link .tmp_vmlinux3 .tmp_kallsyms2.o

		kallsyms .tmp_vmlinux3 .tmp_kallsyms3.o
	fi
fi

info LD vmlinux
vmlinux_link vmlinux "${kallsymso}"

if is_enabled CONFIG_BUILDTIME_EXTABLE_SORT; then
	info SORTEX vmlinux
	sortextable vmlinux
fi

info SYSMAP System.map
mksysmap vmlinux System.map

# step a (see comment above)
if is_enabled CONFIG_KALLSYMS; then
	mksysmap ${kallsyms_vmlinux} .tmp_System.map

	if ! cmp -s System.map .tmp_System.map; then
		echo >&2 Inconsistent kallsyms data
		echo >&2 Try "make KALLSYMS_EXTRA_PASS=1" as a workaround
		exit 1
	fi
fi

