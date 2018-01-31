#!/usr/bin/perl
# This script takes as input a BCL file generated by an Illumina sequencer
# run on a 10XGENOMICS Chromium single cell 3' RNA-seq library, extracts
# the reads, maps them to a transcriptome using kallisto and formats
# the equivalence class counts as input for Seurat.

if ($ARGV[0] =~ /^--?h(elp)?$/) {
  print "commandline is :\n\n";
  print "sc_read_kallisto_wrapper_4test.pl --BCLfile ??? --CSVfile ??? --index ??? --transcriptome ??? --undetermined ??? --expcells ??? --distance ??? \n\n";
  print "arguments :\n";
  print "  --BCLfile : tarred and compressed BCL file\n";
  print "  --CSVfile : IEM file or file in csv format with info about samples\n";
  print "  --index : a kallisto index\n";
  print "  --transcriptome :  the fastA file with a transcriptome used to make the kallisto index\n";
  print "  --undetermined : report reads that could not be assigned to a sample (default : no)\n";
  print "  --expcells : expected number of cells in a sample (default : 3000)\n";
  print "  --distance : minimum distance between cell barcodes (default : 5)\n";
  print
  exit;
}

use Getopt::Long;
use Archive::Extract;
use File::Find;
use File::Copy;
use File::Path qw(make_path remove_tree);

# These must be adapted appropriately
$cellranger = 'XXX/cellranger-2.0.2/cellranger';
$bcl2fastqpath = 'XXX/bcl2fastq/build/cxx/bin';
$kallisto='XXX/kallisto_linux-v0.43.1';
$libdir = 'XXX'; # the location of the Python scripts
$python = '/usr/bin/python';
$Nthreads = 8;

GetOptions(\%options,
  "BCLfile=s",
  "CSVfile=s",
  "index=s", # an FTP object, optional in interface
  "transcriptome=s", # an FTP object, optional in interface
  "undetermined=s", # yes or no (is default) 
  "expcells=i",
  "distance=i"
);
if (not exists $options{undetermined}) { $options{undetermined} = 'no' }
if (not exists $options{expcells}) { $options{expcells} = 3000 }
if (not exists $options{distance}) { $options{distance} = 5 }

# check if CSVfile looks OK, determine if it is the long format (IEM file)
# or the short format and make list of sample names (which we will need
# later if we want to do the mapping)
$csvfile = $options{CSVfile};
open IN, "$csvfile" or die "\nCould not open $csvfile\n";
$firstline = <IN>;
if ($firstline eq "Lane,Sample,Index\n") {
  $CSVtype = 'short';
  while (<IN>) {
    if (not /^\d,[^,]+,[^,]+/) {
      die "$csvfile does not look correct. Read documentation for how to format it.\n";
    }
    $_ =~ /^\d,([^,]+)/;
    $sample_names_used{$1} = 1;
  }
} elsif ($firstline =~ /^\[Header\]/) {
  $line = <IN>;
  if ($line !~ /^IEMFileVersion/) { goto 'NOFORMAT' } 
  $CSVtype = 'long';
  while (<IN>) {
    if ($readingdata) {
      chomp;
      @fields = split /,/;
      $sample_names_used{$fields[$sample_pos]} = 1;
    } else {
      if (/^\[Data\]/) {
        $readingdata = 1;
        $line = <IN>;
        chomp $line;
        @fieldnames = split /,/, $line;
        while (($pos, $fieldname) = each @fieldnames) {
          if ($fieldname eq 'Sample_ID') {
            $sample_id_exists = 1 ; $sample_id_pos = $pos;
          } elsif ($fieldname eq  'Sample_Name') {
            $sample_name_exists = 1 ; $sample_name_pos = $pos;
          } elsif ($fieldname eq 'Lane') {
            $lane_exists = 1;
          } elsif ($fieldname eq 'index') {
            $index_exists = 1;
          } elsif ($fieldname eq 'I7_Index_ID') {
            $index_exists = 1;
          }
        }
        if ($sample_name_exists) {
          $sample_pos = $sample_name_pos;
        } elsif ($sample_id_exists) {
          $sample_pos = $sample_id_pos;
        } else {
          die "$csvfile does not look correct.\nThe [Data] section should contain a field Sample_Name or Sample_ID.\n";
        }
        if (not $lane_exists) {
          warn "$csvfile has no Lane field in its [Data] section.\nIs this OK ?\n";
        }
        if (not $index_exists) {
          die "$csvfile does not look correct.\n The [Data] section should contain a field I7_Index_ID or index.\n";
        }
      }
    }
  }
} else {
  NOFORMAT : die "Could not recognize format of file $csvfile.\nIt should start with :\nLane,Sample,Index\nor with :\n[Header],,,,,,,,\nIEMFileVersion,,,,,,,,\nRead documentation for how to format it.\n";
}
close IN;
@sample_names_used = keys %sample_names_used;
#foreach $sample_name (@sample_names_used) { # for testing
#  print "$sample_name\n";
#}

# Detar the BCL file and parse the RunInfo.xml and RunParameters.xml files.
# Read the name of the flow cell, which will be used by cell ranger
#   as output dir name.
# Read info about the chemistry and the length of the bar codes
$bclfile = $options{BCLfile};
$bclarchive = Archive::Extract->new(archive => $bclfile);
$bclarchive->extract or die "\nCould not extract $bclfile. Are you sure this is a valid compressed BCL file ?\n";
@filesfrombclarchive = @{$bclarchive->files};
foreach $filefrombclarchive (@filesfrombclarchive) {
  if ($filefrombclarchive =~ /^([^\/]+)\/RunInfo.xml$/) {
    $bcldir = $1;
  } 
}
if (not $bcldir) {
  die "\n$bclfile does not contain a file RunInfo.xml. Are you sure this is a valid BCL ?\n";
}
open IN, "$bcldir/RunInfo.xml";
while (<IN>) {
  if (/<Flowcell>(.+)<\/Flowcell>/) {
    $flowcell = $1;
    # print "$flowcell\n"; # for debugging
  }
}
close IN;
if (not $flowcell) {
  die "\n$bcldir/RunInfo.xml does not contain a line <Flowcell>FLOWCELLNAME</Flowcell>, while this is needed for proper execution.\n";
}
# print "$chemistry\n"; # for debugging
open IN, "$bcldir/RunParameters.xml" or open IN, "$bcldir/runParameters.xml";
while (<IN>) {
  if (/<Read1>(\d+)<\/Read1>/) {
     $Lread1 = $1
  } elsif (/<Read2>(\d+)<\/Read2>/) {
     $Lread2 = $1
  } elsif (/<Index1Read>(\d+)<\/Index1Read>/
      or /<IndexRead1>(\d+)<\/IndexRead1>/) {
     $Lindex1 = $1;
  } elsif (/<Index2Read>(\d+)<\/Index2Read>/
      or /<IndexRead2>(\d+)<\/IndexRead2>/) {
     $Lindex2 = $1;
  }
}
# print "$Lread1 $Lread2 $Lindex1 $Lindex2\n";
if ($Lread2 == 10 and $Lindex1 == 14 and $Lindex2 == 8) {
  $chemistry = 'SC3Pv1' ; $cell_barcode_length = 14;
} elsif ($Lread1 >= 26 and $Lindex1 == 8) {
  $chemistry = 'SC3Pv2' ; $cell_barcode_length = 16;
} else {
  die "\nRunParameters.xml does not refer to a known chemistry.\n";
}

# set bcl2fastq in PATH (is needed by cell ranger) and  write and execute
# the cell ranger command
$ENV{PATH} .= ":$bcl2fastqpath";
$cmd = "$cellranger mkfastq --run=$bcldir --localcores=$Nthreads";
if ($CSVtype eq 'short') {
  $cmd .= " --csv=$csvfile";
} elsif ($CSVtype eq  'long') {
  $cmd .= " --samplesheet=$csvfile";
}
if ($options{undetermined} eq 'no') {
  $cmd .= ' --delete-undetermined';
}
# print "$cmd\n"; # for debugging
system "$cmd";

# test if run went well and extract file qc_summary.json from cell ranger output
if (not -e "$flowcell/outs/fastq_path") {
  die "\nSomething went wrong with cell ranger extraction of single cell reads.\nThe folder $flowcell/outs/fastq_path cannot be found.\n";
}
if (-e "$flowcell/outs/qc_summary.json") {
  move("$flowcell/outs/qc_summary.json", '.');
} else {
  warn "file $flowcell/outs/qc_summary.json could not be found\n";
}

# extract fastq files from cell ranger output and put them in directory
#   FASTQ_FILES
make_path('FASTQ_FILES');
$fastqdirs[0] = "$flowcell/outs/fastq_path";
find ({wanted => \&move_fastqfiles, no_chdir => 1}, @fastqdirs);

# clean up unneeded cell ranger output
remove_tree("$bcldir", "$flowcell", "__${flowcell}.mro");

# check if reads from all samples were extracted
foreach $sample_name (@sample_names_used) {
  $FASTQDIRS[0] = 'FASTQ_FILES';
  $found = 0;
  find ({wanted => \&find_samples}, @FASTQDIRS);
  if ($found) {
    push @sample_names, $sample_name;
  } else {
    warn "There are no reads corresponding to sample $sample_name that could be found.\n";
  }
}
if (not exists $sample_names[0]) {
  die "There are no reads to map.\n";
}
#foreach $sample_name (@sample_names) { # for testing
#   print "$sample_name\n";
#}

# check for kallisto index, transcriptome and SAM file
# exit if no kallisto index is provided
if (exists $options{index}) {
  $index = $options{index};
  if (exists $options{transcriptome}) {
    $classes2transcripts = 1;
    $transcriptome = $options{transcriptome};
  }
} else {
  exit;
}

# AT THIS POINT IN THE SCRIPT WE SHIFT FROM USING CELL RANGER TO
# USING THE PACHTERLAB TOOLS.

# for each sample split the data per cell relying on the cell barcodes,
# then map the data to a transcriptome using kallisto.
$error = 0;
foreach $sample_name (@sample_names) {
  open OUT, ">config.json";
    print OUT "{\n";
    print OUT "    \"NUM_THREADS\": $Nthreads,\n";
    print OUT "    \"EXP_CELLS\": $options{expcells},\n";
    print OUT "    \"SOURCE_DIR\": \"$libdir\",\n";
    print OUT "    \"BASE_DIR\": \"FASTQ_FILES/\",\n";
    print OUT "    \"sample_idx\": \"$sample_name\",\n";
    print OUT "    \"SAVE_DIR\": \"CELL_BARCODES/\",\n";
    print OUT "    \"dmin\": $options{distance},\n";
    print OUT "    \"BARCODE_LENGTH\": $cell_barcode_length,\n";
    print OUT "    \"OUTPUT_DIR\": \"FASTQ_SPLIT_PER_CELL/\"\n";
    print OUT "}";
  close OUT;
  make_path('CELL_BARCODES', 'FASTQ_SPLIT_PER_CELL', "${sample_name}_kallisto");
  if ($chemistry eq 'SC3Pv1') {
    system "$python $libdir/get_cell_barcodes_chem1.py config.json";
    system "$python $libdir/error_correct_and_split_chem1.py config.json";
  } elsif ($chemistry eq 'SC3Pv2') {
    system "$python $libdir/get_cell_barcodes_chem2.py config.json";
    system "$python $libdir/error_correct_and_split_chem2.py config.json";
  }
  move('CELL_BARCODES/umi_barcodes.png',"${sample_name}_umi_barcodes.png");
  system "$kallisto/kallisto pseudo -i $index -o ${sample_name}_kallisto --umi -b FASTQ_SPLIT_PER_CELL/umi_read_list.txt -t $Nthreads 2>> stdout.txt";
    # we redirect STDERR of kallisto to STDOUT to avoid error icon
  remove_tree('config.json', 'CELL_BARCODES', 'FASTQ_SPLIT_PER_CELL');
  if (not -e "${sample_name}_kallisto/matrix.cells") { $error =1 }
  if (not -e "${sample_name}_kallisto/matrix.ec") { $error =1 }
  if (not -e "${sample_name}_kallisto/matrix.tsv") { $error =1 }
}
if ($error) {
  die "Something went wrong with the kallisto mapping. Are you sure you provided a correct index ?\n";
}

# if transcriptome is provided, parse it and extract information about
# genes and transcripts for the sake of preparing input for Seurat
if ($classes2transcripts) {
  open IN, $transcriptome; # perform simple test to check if file is OK
  $line = <IN>;
  # print $line; # for testing
  if ($line !~ /^>/) {
    warn "The transcriptome file does not look OK.\nThe first line should start with a >.\n";
    $classes2transcripts = 0;
  }
  close IN;
  open IN, $transcriptome;
  $transcript_ids[0] = 'BOGUS'; # we start effectively at number 1
  while (<IN>) {
    if (/^>([^ \n]+)/) {
      push @transcript_ids, $1;
    }
  }
  close IN;
}

# make from kallisto output input suited for Seurat
foreach $sample_name (@sample_names) {
  make_path("${sample_name}_4Seurat");
  open IN, "${sample_name}_kallisto/matrix.cells";
  open OUT, ">${sample_name}_4Seurat/barcodes.tsv";
  $Ncells = 0;
  while (<IN>) {
    print OUT;
    $Ncells++;
  }
  close IN; close OUT;
  open IN, "${sample_name}_kallisto/matrix.ec";
  open OUT, ">${sample_name}_4Seurat/genes.tsv";
  $Nclasses = 0;
  if ($classes2transcripts) {
    while (<IN>) {
      @fields = split;
      $fields[0]++;
      @items = split /,/, $fields[1];
      for($i=0;$i<=$#items;$i++) {
        $items[$i]++;
        $items[$i] = $transcript_ids[$items[$i]];
      }
      $items = join ',', @items;
      print OUT "$fields[0]\t$items\n";
      $Nclasses++;
    }
  } else {
    while (<IN>) {
      @fields = split;
      $fields[0]++;
      @items = split /,/, $fields[1];
      for($i=0;$i<=$#items;$i++) {
        $items[$i]++;
      }
      $items = join ',', @items;
      print OUT "$fields[0]\t$items\n";
      $Nclasses++;
    }
  }
  close IN; close OUT;
  $Nmappings = 0;
  open IN, "${sample_name}_kallisto/matrix.tsv";
  while (<IN>) {
    $Nmappings++;
  }
  close IN;
  open IN, "${sample_name}_kallisto/matrix.tsv";
  open OUT, ">${sample_name}_4Seurat/matrix.mtx";
  print OUT "%%MatrixMarket matrix coordinate integer general\n%\n";
  print OUT "$Nclasses\t$Ncells\t$Nmappings\n";
  while (<IN>) {
    @fields = split;
    $fields[0]++; $fields[1]++;
    print OUT "$fields[0]\t$fields[1]\t$fields[2]\n";
  }
  close IN; close OUT;
}

################################################################
# subroutines for File::Find::find
# note : first argument of find is a hash, element with key 'wanted' is
# reference to a subroutine that has no arguments or return value
# but runs over $_

sub move_fastqfiles {
  if (/fastq.gz$/) {
    move($_, 'FASTQ_FILES');
  }
}

sub find_samples {
  if (/${sample_name}_.*_I1_001.fastq.gz$/) {
    $found = 1;
  }
}
