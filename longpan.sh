#!/usr/bin/env bash
# Gaurav Sablok
# gsablok@proton.me
#
# Long-read genome assembly / update / polishing / comparison pipeline.
# Rewritten to fix control-flow, quoting, and variable bugs in the original
# script, and to give the interactive prompts a nicer, menu-driven UI.

set -uo pipefail

# ----------------------------------------------------------------------------
# Display helpers (the "enhanced graphical display" layer)
# ----------------------------------------------------------------------------
BOLD=$(tput bold 2>/dev/null || true)
DIM=$(tput dim 2>/dev/null || true)
RESET=$(tput sgr0 2>/dev/null || true)
GREEN=$(tput setaf 2 2>/dev/null || true)
YELLOW=$(tput setaf 3 2>/dev/null || true)
CYAN=$(tput setaf 6 2>/dev/null || true)
RED=$(tput setaf 1 2>/dev/null || true)

banner() { printf "\n%s==> %s%s\n" "${CYAN}${BOLD}" "$1" "${RESET}"; }
info() { printf "%s[info]%s %s\n" "${GREEN}" "${RESET}" "$1"; }
warn() { printf "%s[warn]%s %s\n" "${YELLOW}" "${RESET}" "$1"; }
err() { printf "%s[error]%s %s\n" "${RED}" "${RESET}" "$1" >&2; }

# A real arrow-free but numbered "menu" using bash `select`, instead of the
# original free-text "yes/no" reads. Returns 0 for yes, 1 for no.
ask_yes_no() {
	local question="$1" reply
	printf "%s%s%s\n" "${BOLD}" "$question" "${RESET}"
	select reply in "yes" "no"; do
		case "$reply" in
		yes) return 0 ;;
		no) return 1 ;;
		*) echo "please choose 1 or 2" ;;
		esac
	done
}

# Numbered choice menu, prints the chosen value on stdout.
ask_choice() {
	local question="$1"
	shift
	local options=("$@")
	local reply
	printf "%s%s%s\n" "${BOLD}" "$question" "${RESET}" >&2
	select reply in "${options[@]}"; do
		if [[ -n "${reply:-}" ]]; then
			echo "$reply"
			return 0
		fi
		echo "please pick a valid number" >&2
	done
}

ask_text() {
	local question="$1" var
	read -r -p "${BOLD}${question}: ${RESET}" var
	echo "$var"
}

require_dir() {
	[[ -n "${1:-}" && -d "$1" ]]
}

# ----------------------------------------------------------------------------
# 0. Welcome
# ----------------------------------------------------------------------------
banner "Gaurav Sablok  |  gsablok@proton.me"
info "This tool creates or updates a long-read (PacBio) genome assembly,"
info "optionally polishes it with Illumina reads, computes coverage, and"
info "compares it against a reference with lastz + quast."
info "Required tools: canu, flye, mecat2ref, blasr, lastz, bowtie2, bamtools,"
info "samtools, pilon/jasper, quast, busco."

# ----------------------------------------------------------------------------
# 1. Environment / tool setup
# ----------------------------------------------------------------------------
banner "Environment setup"
if ask_yes_no "Do you already have all required tools installed and on your PATH?"; then
	canupath=$(ask_text "Path to canu bin directory (blank if already on PATH)")
	blasrpath=$(ask_text "Path to blasr bin directory (blank if already on PATH)")
	lastzpath=$(ask_text "Path to lastz bin directory (blank if already on PATH)")
	flyepath=$(ask_text "Path to flye bin directory (blank if already on PATH)")
	mecatpath=$(ask_text "Path to mecat2ref bin directory (blank if already on PATH)")
	bamtoolspath=$(ask_text "Path to bamtools bin directory (blank if already on PATH)")
	bowtie2path=$(ask_text "Path to bowtie2 bin directory (blank if already on PATH)")
	pilonpath=$(ask_text "Path to pilon jar directory (blank if already on PATH)")

	for p in "$canupath" "$blasrpath" "$lastzpath" "$flyepath" "$mecatpath" \
		"$bamtoolspath" "$bowtie2path" "$pilonpath"; do
		[[ -n "$p" ]] && export PATH="${p}:${PATH}"
	done
else
	banner "Creating a conda environment named 'genomeassembly'"
	conda create -n genomeassembly -y &&
		conda install -n genomeassembly -c bioconda -c conda-forge \
			blasr canu lastz flye mecat2 quast pilon bowtie2 bamtools samtools busco -y
	conda clean -t -y
	# NOTE: the original script created the env but never activated it, so
	# none of the tools it installed were actually usable later on.
	# shellcheck disable=SC1091
	source "$(conda info --base)/etc/profile.d/conda.sh"
	conda activate genomeassembly
	info "conda environment 'genomeassembly' created and activated"
fi

for tool in canu flye mecat2ref blasr lastz bowtie2 bowtie2-build bamtools samtools quast; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		warn "'$tool' was not found on PATH. Steps that need it will fail."
	fi
done

# ----------------------------------------------------------------------------
# 2. Basic run parameters
# ----------------------------------------------------------------------------
banner "Run parameters"
species=$(ask_text "Species name (used as a filename prefix)")
if [[ -z "$species" ]]; then
	err "A species name is required. Exiting."
	exit 1
fi

mode=$(ask_choice "What do you want to do?" \
	"Assemble a genome for the first time" \
	"Update an existing assembly with new reads")

do_alignment=false
ask_yes_no "Do you want to compare the assembly against a reference (lastz + quast)?" && do_alignment=true

do_illumina=false
ask_yes_no "Do you want to compute Illumina-based coverage / polishing?" && do_illumina=true

do_polish=false
polish_tool=""
if $do_illumina; then
	ask_yes_no "Do you want to polish the genome as well?" && do_polish=true
	if $do_polish; then
		polish_tool=$(ask_choice "Which polishing tool?" "pilon" "jasper")
	fi
fi

assembler=$(ask_choice "Which assembler do you want to use?" "canu" "flye" "mecatref")

threads=$(ask_text "Number of threads to use")
threads=${threads:-4}

reads=$(ask_text "Path to the directory containing the long (PacBio) reads")
if ! require_dir "$reads"; then
	err "Reads directory '$reads' does not exist. Exiting."
	exit 1
fi

do_removal=false
contaminant=""
if ask_yes_no "Do you want to remove contaminant/reference-matching reads before assembly?"; then
	do_removal=true
	contaminant=$(ask_text "Path to the reference/contaminant fasta for read removal")
fi

mapping=$(ask_text "Number of best matches to keep during blasr mapping (--bestn)")
mapping=${mapping:-1}

case "$assembler" in
canu)
	genome_size=$(ask_text "Estimated genome size for canu (e.g. 3.2g, 500m)")
	sensitivity=$(ask_text "corMhapSensitivity for canu (e.g. normal/high)")
	min_read_len=$(ask_text "Minimum read length for canu")
	meryl_mem=$(ask_text "Memory (GB) for meryl")
	;;
flye)
	genome_size=$(ask_text "Estimated genome size for flye (e.g. 3.2g)")
	flye_overlap=$(ask_text "Minimum overlap for flye")
	;;
mecatref)
	refgenome=$(ask_text "Path to the reference fasta used by mecat2ref")
	if [[ ! -f "$refgenome" ]]; then
		err "Reference fasta '$refgenome' not found. Exiting."
		exit 1
	fi
	;;
esac

illumina_dir=""
if $do_illumina; then
	illumina_dir=$(ask_text "Path to the directory containing Illumina paired reads (*_R1/_R2.fastq[.gz])")
	if ! require_dir "$illumina_dir"; then
		err "Illumina reads directory '$illumina_dir' does not exist. Exiting."
		exit 1
	fi
fi

threshold=""
lastz_coverage=""
align_format=""
comparison=""
comparison_gff=""
if $do_alignment; then
	comparison=$(ask_text "Path to the reference genome fasta for comparison")
	comparison_gff=$(ask_text "Path to the reference GFF for comparison (optional)")
	threshold=$(ask_text "Identity threshold %% for lastz (blank = default 75)")
	lastz_coverage=$(ask_text "Coverage %% for lastz (blank = default 60)")
	align_format=$(ask_choice "Alignment output format" "sam" "general")
	threshold=${threshold:-75}
	lastz_coverage=${lastz_coverage:-60}
fi

previous_assembly=""
new_reads_dir=""
if [[ "$mode" == "Update an existing assembly with new reads" ]]; then
	previous_assembly=$(ask_text "Path to the previous assembly fasta")
	new_reads_dir=$(ask_text "Path to the directory containing the new long reads")
	if ! require_dir "$new_reads_dir"; then
		err "New reads directory '$new_reads_dir' does not exist. Exiting."
		exit 1
	fi
fi

workdir="$(pwd)"
banner "Configuration summary"
cat <<SUMMARY
  species          : $species
  mode             : $mode
  assembler        : $assembler
  threads          : $threads
  long reads dir   : $reads
  contaminant rm   : $do_removal ${contaminant:+($contaminant)}
  illumina step    : $do_illumina ${illumina_dir:+($illumina_dir)}
  polish step      : $do_polish ${polish_tool:+($polish_tool)}
  alignment step   : $do_alignment ${comparison:+(vs $comparison)}
  working directory: $workdir
SUMMARY

ask_yes_no "Proceed with these settings?" || {
	err "Aborted by user."
	exit 1
}

# ----------------------------------------------------------------------------
# 3. Directory scaffold
# ----------------------------------------------------------------------------
long_reads_dir="${workdir}/reads_assembly"
assembly_dir="${workdir}/genome_assembly"
illumina_work_dir="${workdir}/illumina_reads"
polished_dir="${workdir}/polished_genome"
sam_dir="${workdir}/sam_file_illumina"
new_reads_work_dir="${workdir}/new_genomic_reads"
combined_dir="${workdir}/combined_assembly"

mkdir -p "$long_reads_dir" "$assembly_dir" "$polished_dir" "$sam_dir"
$do_illumina && mkdir -p "$illumina_work_dir"
[[ "$mode" == "Update an existing assembly with new reads" ]] && mkdir -p "$new_reads_work_dir" "$combined_dir"

# ----------------------------------------------------------------------------
# 4. Prepare long reads
# ----------------------------------------------------------------------------
prepare_long_reads() {
	local src_dir="$1" dest_dir="$2" out_name="$3"
	banner "Preparing long reads from $src_dir"
	local gz_files=("$src_dir"/*.gz)
	if [[ -e "${gz_files[0]}" ]]; then
		for f in "${gz_files[@]}"; do
			gunzip -k -f "$f"
		done
	fi
	local fasta_files=("$src_dir"/*.fasta "$src_dir"/*.fa)
	: >"${dest_dir}/${out_name}"
	for f in "${fasta_files[@]}"; do
		[[ -e "$f" ]] && cat "$f" >>"${dest_dir}/${out_name}"
	done
	info "Wrote ${dest_dir}/${out_name}"
}

prepare_long_reads "$reads" "$long_reads_dir" "all_reads.fasta"

if [[ "$mode" == "Update an existing assembly with new reads" ]]; then
	cp -r "${previous_assembly}" "${combined_dir}/" 2>/dev/null || true
	prepare_long_reads "$new_reads_dir" "$new_reads_work_dir" "new_reads.fasta"
	cat "${new_reads_work_dir}/new_reads.fasta" >>"${long_reads_dir}/all_reads.fasta"
fi

# ----------------------------------------------------------------------------
# 5. Prepare Illumina reads
# ----------------------------------------------------------------------------
prepare_illumina_reads() {
	banner "Preparing Illumina reads from $illumina_dir"
	local gz_files=("$illumina_dir"/*.gz)
	if [[ -e "${gz_files[0]}" ]]; then
		for f in "${gz_files[@]}"; do
			gunzip -k -f "$f"
		done
	fi
	: >"${illumina_work_dir}/final.R1.fastq"
	: >"${illumina_work_dir}/final.R2.fastq"
	local r1_files=("$illumina_dir"/*R1*.fastq)
	local r2_files=("$illumina_dir"/*R2*.fastq)
	[[ -e "${r1_files[0]}" ]] && cat "${r1_files[@]}" >>"${illumina_work_dir}/final.R1.fastq"
	[[ -e "${r2_files[0]}" ]] && cat "${r2_files[@]}" >>"${illumina_work_dir}/final.R2.fastq"
	info "Wrote final.R1.fastq and final.R2.fastq into $illumina_work_dir"
}

$do_illumina && prepare_illumina_reads

# ----------------------------------------------------------------------------
# 6. Optional contaminant / reference read removal via blasr
# ----------------------------------------------------------------------------
long_reads_fasta="${long_reads_dir}/all_reads.fasta"
cleaned_reads="${assembly_dir}/${species}.unaligned.fasta"

if $do_removal; then
	banner "Removing contaminant / reference-matching reads with blasr"
	(cd "$long_reads_dir" &&
		blasr all_reads.fasta "$contaminant" --bestn "$mapping" --bam \
			"${species}.bam" --unaligned "${species}.unaligned.fasta")
	cp "${long_reads_dir}/${species}.unaligned.fasta" "$cleaned_reads"
else
	cp "$long_reads_fasta" "$cleaned_reads"
fi

# ----------------------------------------------------------------------------
# 7. Assembly
# ----------------------------------------------------------------------------
run_canu() {
	banner "Running canu"
	(cd "$assembly_dir" &&
		canu -p "${species}" -d canu_out \
			genomeSize="${genome_size}" \
			corMhapSensitivity="${sensitivity}" \
			minReadLength="${min_read_len}" \
			merylMemory="${meryl_mem}" \
			gnuplotImageFormat=png \
			useGrid=false \
			ovsThreads="${threads}" ovbThreads="${threads}" \
			-pacbio-raw "${cleaned_reads}")
	genome_fasta=$(find "${assembly_dir}/canu_out" -maxdepth 1 -name '*.contigs.fasta' | head -n1)
}

run_flye() {
	banner "Running flye"
	flye --pacbio-raw "$cleaned_reads" \
		--genome-size "$genome_size" \
		--threads "$threads" \
		--out-dir "${assembly_dir}/flye_out" \
		--min-overlap "$flye_overlap"
	genome_fasta="${assembly_dir}/flye_out/assembly.fasta"
}

run_mecatref() {
	banner "Running mecat2ref"
	mkdir -p "${assembly_dir}/mecat_out"
	mecat2ref -d "$cleaned_reads" -r "$refgenome" \
		-o "${assembly_dir}/mecat_out/${species}.reference.sam" \
		-w "${assembly_dir}/mecat_out/${species}_intermediate" \
		-t "$threads" -n 20 -b 50 -m 2 -x 0
	genome_fasta="${assembly_dir}/mecat_out/${species}.reference.sam"
}

case "$assembler" in
canu) run_canu ;;
flye) run_flye ;;
mecatref) run_mecatref ;;
esac

if [[ -z "${genome_fasta:-}" || ! -e "$genome_fasta" ]]; then
	err "Assembly step did not produce an expected output file. Stopping."
	exit 1
fi
info "Assembly output: $genome_fasta"

# ----------------------------------------------------------------------------
# 8. Reference comparison: lastz + quast
# ---------------------------------------------------------------------------
if $do_alignment; then
	banner "Running lastz against $comparison"
	lastz_fmt="sam"
	[[ "$align_format" == "general" ]] && lastz_fmt="general"
	lastz "${comparison}[multiple]" "$genome_fasta" \
		--identity="$threshold" --coverage="$lastz_coverage" \
		--format="$lastz_fmt" --ambiguous=iupac \
		--output "${assembly_dir}/${species}.refalignments.${lastz_fmt}"
	info "Alignment written to ${assembly_dir}/${species}.refalignments.${lastz_fmt}"

	banner "Running quast"
	quast_args=("$genome_fasta" -r "$comparison" -o "${assembly_dir}/${species}.quast_report"
		--min-contig 500 -t "$threads")
	[[ -n "$comparison_gff" ]] && quast_args+=(-g "$comparison_gff")
	quast "${quast_args[@]}"
fi

# ----------------------------------------------------------------------------
# 9. Illumina coverage
# ----------------------------------------------------------------------------
sorted_bams=()
if $do_illumina; then
	banner "Building bowtie2 index and aligning Illumina reads"
	cp "$genome_fasta" "${illumina_work_dir}/reference.fasta"
	(cd "$illumina_work_dir" && bowtie2-build "reference.fasta" "${species}_index")
	bowtie2 -p "$threads" --very-sensitive-local \
		-x "${illumina_work_dir}/${species}_index" \
		-1 "${illumina_work_dir}/final.R1.fastq" \
		-2 "${illumina_work_dir}/final.R2.fastq" \
		-S "${sam_dir}/${species}.sam" \
		--no-unal --al-conc "${sam_dir}/${species}.aligned.fastq"

	banner "Computing coverage / stats with samtools + bamtools"
	for samfile in "${sam_dir}"/*.sam; do
		[[ -e "$samfile" ]] || continue
		local_bam="${samfile%.sam}.bam"
		sorted_bam="${samfile%.sam}.sorted.bam"
		samtools view -b -o "$local_bam" "$samfile"
		bamtools coverage -in "$local_bam" -out "${samfile%.sam}.coverage.txt"
		bamtools stats -in "$local_bam" -insert >"${samfile%.sam}.stats.txt"
		bamtools sort -in "$local_bam" -out "$sorted_bam"
		cp "$sorted_bam" "$polished_dir/"
		sorted_bams+=("${polished_dir}/$(basename "$sorted_bam")")
	done
fi

# ----------------------------------------------------------------------------
# 10. Polishing
# ----------------------------------------------------------------------------
if $do_polish; then
	banner "Polishing genome with $polish_tool"
	cp "$genome_fasta" "${polished_dir}/${species}.pre_polish.fasta"

	if [[ "$polish_tool" == "jasper" ]]; then
		jasper_bin="${polished_dir}/jasper-1.0.3/bin/jasper.sh"
		if [[ ! -x "$jasper_bin" ]]; then
			(cd "$polished_dir" &&
				wget -q https://github.com/alguoo314/JASPER/releases/download/v1.0.3/jasper-1.0.3.tar.gz &&
				tar zxf jasper-1.0.3.tar.gz &&
				cd jasper-1.0.3 && ./configure --prefix="$PWD" && make install)
		fi
		export PATH="${polished_dir}/jasper-1.0.3:${PATH}"
		jasper.sh -t "$threads" "${polished_dir}/${species}.pre_polish.fasta" \
			-r "${illumina_work_dir}/final.R1.fastq" "${illumina_work_dir}/final.R2.fastq"
	else
		if [[ ${#sorted_bams[@]} -eq 0 ]]; then
			err "No sorted BAM files available for pilon. Skipping polish step."
		else
			java -Xmx100g -jar pilon.jar --genome "${polished_dir}/${species}.pre_polish.fasta" \
				--frags "${sorted_bams[0]}" \
				--output "${species}.polished_genome" \
				--outdir "$polished_dir" \
				--threads "$threads" --changes --fix all --mindepth 10
		fi
	fi
fi

banner "Pipeline finished"
info "Assembly:   $genome_fasta"
$do_alignment && info "Alignments: ${assembly_dir}/${species}.refalignments.${lastz_fmt}"
$do_polish && info "Polished genome written to: $polished_dir"
