=head1 NAME

VertRes::Parser::bam - parse and write bam files

=head1 SYNOPSIS

use VertRes::Parser::bam;

# create object, supplying bam file (filehandles not supported)
my $pars = VertRes::Parser::bam->new(file => 'my.bam');

# get header information
my $program = $pars->program();
my %readgroup_info = $pars->readgroup_info();
# etc.

# get the hash reference that will hold the most recently requested result
my $result_holder = $pars->result_holder();

# loop through the output, getting results
while ($pars->next_result()) {
    # check $result_holder for desired info, eg:
    my $flag = $result_holder->{FLAG};
    
    # get info about a flag, eg:
    my $mapped = $pars->is_mapped($flag);
}

# or for speed critical situations, parsing bam records only:
$pars = VertRes::Parser::sam->new(file => 'in.bam');
while (my @fields = $pars->get_fields('QNAME', 'FLAG', 'RG')) {
    # @fields contains the qname, flag and rg tag
    if ($pars->is_mapped($fields[1])) {
        # write mapped records out to a new bam, ignoring OQ tags to make the
        # output smaller
        $pars->ignore_tags_on_write("OQ");
        $pars->write("mapped.bam");
    }
}

=head1 DESCRIPTION

A parser for bam files (not sam files).

The environment variable SAMTOOLS must point to a directory where samtools
source has been compiled, so containing at least bam.h and libbam.a.
See http://cpansearch.perl.org/src/LDS/Bio-SamTools-1.06/README for advice on
gettings things to work. Specifically, you'll probably need to add -fPIC and
-m64 to the CFLAGS line in samtools's Makefile before compiling.

=head1 AUTHOR

Sendu Bala: bix@sendu.me.uk

=cut

package VertRes::Parser::bam;

use strict;
use warnings;
use Cwd qw(abs_path);
use Inline C => Config => FILTERS => 'Strip_POD' =>
           INC => "-I$ENV{SAMTOOLS}" =>
           LIBS => "-L$ENV{SAMTOOLS} -lbam -lz" =>
           CCFLAGS => '-D_IOLIB=2 -D_FILE_OFFSET_BITS=64';

use base qw(VertRes::Parser::ParserI);

=head2 new

 Title   : new
 Usage   : my $obj = VertRes::Parser::bam->new(file => 'filename');
 Function: Build a new VertRes::Parser::bam object.
 Returns : VertRes::Parser::bam object
 Args    : file => filename

=cut

sub new {
    my ($class, @args) = @_;
    
    my $self = $class->SUPER::new(@args);
    
    # unlike normal parsers, our result holder is a hash ref
    $self->{_result_holder} = {};
    
    return $self;
}

=head2 file

 Title   : file
 Usage   : $obj->file('filename.bam');
 Function: Get/set filename; when setting also opens the file and sets fh().
           There is also read support for remote files like
           'ftp://ftp..../file.bam' and it will be downloaded to a temporary
           location and opened.
 Returns : absolute path of file
 Args    : filename

=cut

sub file {
    my ($self, $filename) = @_;
    
    if ($filename) {
        if ($filename =~ /^ftp:|^http:/) {
            $filename = $self->get_remote_file($filename) || $self->throw("Could not download remote file '$filename'");
        }
        
        # avoid potential problems with caller changing dir and things being
        # relative; also more informative and explicit to throw with full path
        $filename = abs_path($filename);
        
        # set up the open command which is just for the header
        my $open = "samtools view -H $filename |";
        
        # go ahead and open it (3 arg form not working when middle is optional)
        open(my $fh, $open) || $self->throw("Couldn't open '$open': $!");
        
        $self->{_filename} = $filename;
        $self->fh($fh);
        
        # open in the C API
        my $fh_id = $self->_fh_id;
        unless (defined $self->{"_opened_$fh_id"}) {
            ($self->{_chead}, $self->{_cbam}, $self->{_cb}) = $self->_initialize_bam($filename);
            $self->{"_opened_$fh_id"} = 1;
        }
    }
    
    return $self->{_filename};
}

=head2 close

 Title   : close
 Usage   : $obj->close();
 Function: Ends the read of this sam/bam.
 Returns : n/a
 Args    : n/a

=cut

sub close {
    my $self = shift;
    
    my $fh = $self->fh();
    
    if ($fh) {
        # make sure we've finished reading the whole thing before attempting to
        # close
        while (<$fh>) {
            next;
        }
        
        my $fh_id = $self->_fh_id;
        if (defined $self->{"_opened_$fh_id"}) {
            $self->_close_bam($self->{_cbam});
        }
        while (my ($key, $val) = each %{$self->{writes} || {}}) {
            $self->_close_bam($val);
        }
    }
    
    return $self->SUPER::close();
}

use Inline C => <<'END_C';

=head2 is_sequencing_paired

 Title   : is_sequencing_paired
 Usage   : if ($obj->is_sequencing_paired($flag)) { ... };
 Function: Ask if a given flag indicates the read was paired in sequencing.
 Returns : boolean
 Args    : int (the flag recieved from $result_holder->{FLAG})

=cut

int is_sequencing_paired(SV* self, int flag) {
    return (flag & 0x0001) > 0 ? 1 : 0;
}

=head2 is_mapped_paired

 Title   : is_mapped_paired
 Usage   : if ($obj->is_mapped_paired($flag)) { ... };
 Function: Ask if a given flag indicates the read was mapped in a proper pair.
 Returns : boolean
 Args    : int (the flag recieved from $result_holder->{FLAG})

=cut

int is_mapped_paired(SV* self, int flag) {
    return (flag & 0x0002) > 0 ? 1 : 0;
}

=head2 is_mapped

 Title   : is_mapped
 Usage   : if ($obj->is_mapped($flag)) { ... };
 Function: Ask if a given flag indicates the read was itself mapped.
 Returns : boolean
 Args    : int (the flag recieved from $result_holder->{FLAG})

=cut

int is_mapped(SV* self, int flag) {
    return (flag & 0x0004) == 0 ? 1 : 0;
}

=head2 is_mate_mapped

 Title   : is_mate_mapped
 Usage   : if ($obj->is_mate_mapped($flag)) { ... };
 Function: Ask if a given flag indicates the read's mate was mapped.
 Returns : boolean
 Args    : int (the flag recieved from $result_holder->{FLAG})

=cut

int is_mate_mapped(SV* self, int flag) {
    return (flag & 0x0008) == 0 ? 1 : 0;
}

=head2 is_reverse_strand

 Title   : is_reverse_strand
 Usage   : if ($obj->is_reverse_strand($flag)) { ... };
 Function: Ask if a given flag indicates the read is on the reverse stand.
 Returns : boolean
 Args    : int (the flag recieved from $result_holder->{FLAG})

=cut

int is_reverse_strand(SV* self, int flag) {
    return (flag & 0x0010) > 0 ? 1 : 0;
}

=head2 is_mate_reverse_strand

 Title   : is_mate_reverse_strand
 Usage   : if ($obj->is_mate_reverse_strand($flag)) { ... };
 Function: Ask if a given flag indicates the read's mate is on the reverse
           stand.
 Returns : boolean
 Args    : int (the flag recieved from $result_holder->{FLAG})

=cut

int is_mate_reverse_strand(SV* self, int flag) {
    return (flag & 0x0020) > 0 ? 1 : 0;
}

=head2 is_first

 Title   : is_first
 Usage   : if ($obj->is_first($flag)) { ... };
 Function: Ask if a given flag indicates the read was the first of a pair.
 Returns : boolean
 Args    : int (the flag recieved from $result_holder->{FLAG})

=cut

int is_first(SV* self, int flag) {
    return (flag & 0x0040) > 0 ? 1 : 0;
}

=head2 is_second

 Title   : is_second
 Usage   : if ($obj->is_second($flag)) { ... };
 Function: Ask if a given flag indicates the read was the second of a pair.
 Returns : boolean
 Args    : int (the flag recieved from $result_holder->{FLAG})

=cut

int is_second(SV* self, int flag) {
    return (flag & 0x0080) > 0 ? 1 : 0;
}

=head2 is_primary

 Title   : is_primary
 Usage   : if ($obj->is_primary($flag)) { ... };
 Function: Ask if a given flag indicates the read alignment was primary.
 Returns : boolean
 Args    : int (the flag recieved from $result_holder->{FLAG})

=cut

int is_primary(SV* self, int flag) {
    return (flag & 0x0100) == 0 ? 1 : 0;
}

=head2 passes_qc

 Title   : passes_qc
 Usage   : if ($obj->passes_qc($flag)) { ... };
 Function: Ask if a given flag indicates the read passes quality checks.
 Returns : boolean
 Args    : int (the flag recieved from $result_holder->{FLAG})

=cut

int passes_qc(SV* self, int flag) {
    return (flag & 0x0200) == 0 ? 1 : 0;
}

=head2 is_duplicate

 Title   : is_duplicate
 Usage   : if ($obj->is_duplicate($flag)) { ... };
 Function: Ask if a given flag indicates the read was a duplicate.
 Returns : boolean
 Args    : int (the flag recieved from $result_holder->{FLAG})

=cut

int is_duplicate(SV* self, int flag) {
    return (flag & 0x0400) > 0 ? 1 : 0;
}

END_C

=head2 sam_version

 Title   : sam_version
 Usage   : my $sam_version = $obj->sam_version();
 Function: Return the file format version of this sam file, as given in the
           header.
 Returns : number (undef if no header)
 Args    : n/a

=cut

sub sam_version {
    my $self = shift;
    return $self->_get_single_header_tag('HD', 'VN');
}

=head2 group_order

 Title   : group_order
 Usage   : my $group_order = $obj->group_order();
 Function: Return the group order of this sam file, as given in the header.
 Returns : string (undef if no header or not given in header)
 Args    : n/a

=cut

sub group_order {
    my $self = shift;
    return $self->_get_single_header_tag('HD', 'GO');
}

=head2 sort_order

 Title   : sort_order
 Usage   : my $sort_order = $obj->sort_order();
 Function: Return the sort order of this sam file, as given in the header.
 Returns : string (undef if no header or not given in header)
 Args    : n/a

=cut

sub sort_order {
    my $self = shift;
    return $self->_get_single_header_tag('HD', 'SO');
}

=head2 program_info

 Title   : program_info
 Usage   : my %all_program_info = $obj->program_info();
 Function: Get information about the programs used to create/process this bam,
           as reported in the header.
 Returns : undef if no PG lines in header, else:
           with no args: hash (keys are program ids, values are hash refs with
                               keys as tags (like VN and CL))
           with just a program id: hash (keys as tags, like VN and CL)
           with a program and a tag: the value of that tag for that program
 Args    : none for all info,
           program id for all the info for just that program,
           program id and tag (like 'VN' or 'CL') for specific info

=cut

sub program_info {
    my $self = shift;
    return $self->_handle_multi_line_header_types('PG', @_);
}

=head2 program

 Title   : program
 Usage   : my $program = $obj->program();
 Function: Return the program used to do the mapping, as given in the header.
           If there is more than 1 PG header line, tries to guess which one is
           for the mapping program.
 Returns : string (undef if no header or not given in header)
 Args    : n/a

=cut

sub program {
    my $self = shift;
    return $self->_guess_mapping_program();
}

sub _guess_mapping_program {
    my $self = shift;
    
    my %info = $self->program_info();
    my @programs = keys %info;
    
    if (@programs == 1) {
        return $programs[0];
    }
    else {
        foreach my $program (@programs) {
            if ($program =~ /bwa|maq|ssha|bfast|stampy/ || $program !~ /GATK/) {
                return $program;
            }
        }
        
        # guess randomly
        return $programs[0];
    }
}

=head2 program_version

 Title   : program_version
 Usage   : my $program_version = $obj->program_version();
 Function: Return the program version used to do the mapping, as given in the
           header.
           If there is more than 1 PG header line, tries to guess which one is
           for the mapping program.
 Returns : string (undef if no header or not given in header)
 Args    : n/a

=cut

sub program_version {
    my $self = shift;
    my $program_id = $self->_guess_mapping_program();
    return $self->program_info($program_id, 'VN');
}

=head2 command_line

 Title   : command_line
 Usage   : my $command_line = $obj->command_line();
 Function: Return the command line used to do the mapping, as given in the
           header.
           If there is more than 1 PG header line, tries to guess which one is
           for the mapping program.
 Returns : string (undef if no header or not given in header)
 Args    : n/a

=cut

sub command_line {
    my $self = shift;
    my $program_id = $self->_guess_mapping_program();
    return $self->program_info($program_id, 'CL');
}

=head2 sequence_info

 Title   : sequence_info
 Usage   : my %all_sequences_info = $obj->sequence_info();
           my %sequence_info = $obj->sequence_info('chr1');
           my $seq_length = $obj->sequence_info('chr1', 'LN');
 Function: Get information about the reference sequences, as reported in the
           header.
 Returns : undef if no SQ lines in header, else:
           with no args: hash (keys are sequence ids, values are hash refs with
                               keys as tags (like LN and M5))
           with just a sequence id: hash (keys as tags, like LN and M5)
           with a sequence and a tag: the value of that tag for that sequence
 Args    : none for all info,
           sequence id for all the info for just that sequence,
           sequence id and tag (like 'LN' or 'M5') for specific info

=cut

sub sequence_info {
    my $self = shift;
    return $self->_handle_multi_line_header_types('SQ', @_);
}

=head2 readgroup_info

 Title   : readgroup_info
 Usage   : my %all_rg_info = $obj->readgroup_info();
           my %rg_info = $obj->readgroup_info('SRR00001');
           my $library = $obj->readgroup_info('SRR00001', 'LB');
 Function: Get information about the read groups, as reported in the header.
 Returns : undef if no RG lines in header, else:
           with no args: hash (keys are readgroups, values are hash refs with
                               keys as tags (like LB and SM))
           with just a readgroup id: hash (keys as tags, like LB and SM)
           with a readgroup and a tag: the value of that tag for that readgroup
 Args    : none for all info,
           readgroup id for all the info for just that readgroup,
           readgroup id and tag (like 'LB' or 'SM') for specific info

=cut

sub readgroup_info {
    my $self = shift;
    return $self->_handle_multi_line_header_types('RG', @_);
}

=head2 samples

 Title   : samples
 Usage   : my @samples = $obj->samples();
 Function: Get all the unique SM fields from amongst all RG lines in
           the header.
 Returns : list of strings (sample names)
 Args    : none

=cut

sub samples {
    my $self = shift;
    return $self->_get_unique_rg_fields('SM');
}

sub _get_unique_rg_fields {
    my ($self, $field) = @_;
    my %vals;
    my %rg_info = $self->readgroup_info();
    while (my ($rg, $data) = each %rg_info) {
        $vals{$data->{$field} || next} = 1;
    }
    my @uniques = sort keys %vals;
    return @uniques;
}

sub _handle_multi_line_header_types {
    my ($self, $type, $id, $tag) = @_;
    
    my $lines = $self->_get_header_type($type) || return;
    
    # organise the data into by-id hash
    my %all_info;
    foreach my $line (@{$lines}) {
        my %this_data = $self->_tags_to_hash(@{$line});
        my $this_id = $this_data{SN} || $this_data{ID};
        delete $this_data{SN};
        delete $this_data{ID};
        
        $all_info{$this_id} = \%this_data;
    }
    
    if ($id) {
        my $id_info = $all_info{$id} || return;
        if ($tag) {
            return $id_info->{$tag};
        }
        else {
            return %{$id_info};
        }
    }
    else {
        return %all_info;
    }
}

sub _get_single_header_tag {
    my ($self, $type, $tag) = @_;
    
    my $type_data = $self->_get_header_type($type) || return;
    
    my %data = $self->_tags_to_hash(@{$type_data});
    
    return $data{$tag};
}

sub _tags_to_hash {
    my ($self, @tags) = @_;
    
    my %hash;
    foreach my $tag (@tags) {
        my ($this_tag, $value) = $tag =~ /^(\w\w):(.+)/;
        $hash{$this_tag} = $value;
    }
    return %hash;
}

sub _get_header_type {
    my ($self, $type) = @_;
    
    my $fh = $self->fh() || return;
    my $fh_id = $self->_fh_id;
    
    $self->_get_header();
    
    if (defined $self->{'_header'.$fh_id} && defined $self->{'_header'.$fh_id}->{$type}) {
        return $self->{'_header'.$fh_id}->{$type};
    }
    
    return;
}

sub _get_header {
    my $self = shift;
    
    my $fh = $self->fh() || return;
    my $fh_id = $self->_fh_id;
    
    return if $self->{'_got_header'.$fh_id};
    
    my $non_header;
    while (<$fh>) {
        if (/^@/) {
            #@HD     VN:1.0  GO:none SO:coordinate
            #@SQ     SN:1    LN:247249719    AS:NCBI36       UR:file:/nfs/sf8/G1K/ref/human_b36_female.fa    M5:28f4ff5cf14f5931d0d531a901236378
            #@RG     ID:SRR003447    PL:ILLUMINA     PU:BI.PE1.080723_SL-XBH_0003_FC3044EAAXX.7    LB:Solexa-5453    PI:500  SM:NA11918      CN:BI
            #@PG     ID:xxxx    VN:xxx  CL:xxx
            my @tags = split("\t", $_);
            my $type = shift @tags;
            $type = substr($type, 1);
            
            if ($type eq 'HD') {
                # we only expect and handle one of these lines per file
                $self->{'_header'.$fh_id}->{$type} = \@tags;
            }
            else {
                push(@{$self->{'_header'.$fh_id}->{$type}}, \@tags);
            }
        }
        else {
            # allow header line to not be present
            $non_header = $_;
            last;
        }
    }
    
    $self->{'_got_header'.$fh_id} = 1;
    $self->{'_first_record'.$fh_id} = $non_header;
}

=head2 get_fields

 Title   : get_fields
 Usage   : $obj->get_fields('QNAME', 'FLAG', 'RG');
 Function: For efficiency reasons, next_result() will not parse each result at
           all by default, so your result_holder will be empty. Use this method
           to choose which values you need to parse out. Your result_holder
           hash will then be populated with those only.
 Returns : n/a
 Args    : list of desired fields. Valid ones are:
           QNAME
           FLAG
           RNAME
           POS
           MAPQ
           CIGAR
           MRNM
           MPOS
           ISIZE
           SEQ
           QUAL
           additionaly, there are the psuedo-fields 'SEQ_LENGTH' to get the
           raw length of the read (including hard/soft clipped bases) and
           'MAPPED_SEQ_LENGTH' (only bases that match or mismatch to the
           reference, ie. cigar operator M).
           furthermore you can also request optional tags, such as 'RG'.

=cut

sub get_fields {
    my ($self, @fields) = @_;
    
    $self->{_fields} = [@fields];
}

=head2 result_holder

 Title   : result_holder
 Usage   : my $result_holder = $obj->result_holder()
 Function: Get the data structure that will hold the last result requested by
           next_result()
 Returns : hash ref, with keys corresponding to what you chose in get_fields().
           If you never called get_fields(), the hash will be empty.
           If you requseted a tag and it wasn't present, the value will be set
           to '*'.
 Args    : n/a

=cut

=head2 next_result

 Title   : next_result
 Usage   : while ($obj->next_result()) { # look in result_holder }
 Function: Access the next line from the bam file.
 Returns : boolean (false at end of output; check the result_holder for the
           actual result information)
 Args    : n/a

=cut

=head2 write

 Title   : write
 Usage   : $obj->write("out.bam");
 Function: Write the most recent result retrieved with next_result() (not
           just the fields you got - the whole thing) out to a new bam file
           (which will inherit its header from the input bam you're parsing).
           Calling ignore_tags_on_write() before this will modify what is
           written.
 Returns : n/a
 Args    : output bam file

=cut

sub write {
    my ($self, $out_bam) = @_;
    
    $self->{_cb} || $self->throw("get_fields() must be called before write()");
    
    unless (defined $self->{writes} && defined $self->{writes}->{$out_bam}) {
        ($self->{writes}->{$out_bam}) = $self->_initialize_obam($out_bam);
        $self->_write_header($self->{writes}->{$out_bam}, $self->{_chead});
    }
    
    $self->_write($self->{writes}->{$out_bam}, $self->{_cb}, @{$self->{_ignore_tags} || []});
}

=head2 ignore_tags_on_write

 Title   : ignore_tags_on_write
 Usage   : $obj->ignore_tags_on_write(qw(OQ XM XG XO));
 Function: When using get_fields() and prior to calling write(), ignore the
           given tags so that they will not be output. You only need to call
           this once (don't put it in your get_fields loop).
 Returns : n/a
 Args    : list of tags to ignore

=cut

sub ignore_tags_on_write {
    my ($self, @tags) = @_;
    
    $self->{_ignore_tags} = [@tags];
}

use Inline C => <<'END_C';

#include "bam.h"

void _initialize_bam(SV* self, char* bamfile) {
    bamFile *bam;
    bam = bam_open(bamfile, "r");
    
    bam1_t *b;
    b = bam_init1();
    
    bam_header_t *bh;
    bgzf_seek(bam,0,0);
    bh = bam_header_read(bam);
    
    Inline_Stack_Vars;
    Inline_Stack_Reset;
    Inline_Stack_Push(newRV_noinc(newSViv(bh)));
    Inline_Stack_Push(newRV_noinc(newSViv(bam)));
    Inline_Stack_Push(newRV_noinc(newSViv(b)));
    Inline_Stack_Done;
}

void _initialize_obam(SV* self, char* bamfile) {
    bamFile *bam;
    bam = bam_open(bamfile, "w");
    
    Inline_Stack_Vars;
    Inline_Stack_Reset;
    Inline_Stack_Push(newRV_noinc(newSViv(bam)));
    Inline_Stack_Done;
}

void _write(SV* self, SV* bam_ref, SV* b_ref, ...) {
    bamFile *bam;
    bam = (bamFile*)SvIV(SvRV(bam_ref));
    bam1_t *b;
    b = (bam1_t*)SvIV(SvRV(b_ref));
    
    char *tag;
    STRLEN tag_length;
    uint8_t *tag_value;
    int i;
    
    Inline_Stack_Vars;
    Inline_Stack_Reset;
    for (i = 2; i < Inline_Stack_Items; i++) {
        tag = SvPV(Inline_Stack_Item(i), tag_length);
        tag_value = bam_aux_get(b, tag);
        if (tag_value) {
            bam_aux_del(b, tag_value);
        }
    }
    Inline_Stack_Done;
    
    bam_write1(bam, b);
}

void _write_header(SV* self, SV* bam_ref, SV* header_ref) {
    bamFile *bam;
    bam = (bamFile*)SvIV(SvRV(bam_ref));
    bam_header_t *header;
    header = (bam_header_t*)SvIV(SvRV(header_ref));
    
    bam_header_write(bam, header);
}

void _close_bam(SV* self, SV* bam_ref) {
    bamFile *bam;
    bam = (bamFile*)SvIV(SvRV(bam_ref));
    bam_close(bam);
}

void next_result(SV* self) {
    HV* self_hash;
    self_hash = (HV*)SvRV(self);
    
    U32* keylen;
    keylen = 5;
    if (! hv_exists(self_hash, "_cbam", keylen)) {
        return 0;
    }
    SV* bam_ref;
    bam_ref = *(hv_fetch(self_hash, "_cbam", keylen, 0));
    bamFile *bam;
    bam = (bamFile*)SvIV(SvRV(bam_ref));
    
    SV* b_ref;
    keylen = 3;
    b_ref = *(hv_fetch(self_hash, "_cb", keylen, 0));
    bam1_t *b;
    b = (bam1_t*)SvIV(SvRV(b_ref));
    
    Inline_Stack_Vars;
    Inline_Stack_Reset;
    if (bam_read1(bam, b) >= 0) {
        SV* rh_ref;
        keylen = 14;
        rh_ref = *(hv_fetch(self_hash, "_result_holder", keylen, 0));
        HV* rh_hash;
        rh_hash = (HV*)SvRV(rh_ref);
        hv_clear(rh_hash);
        
        keylen = 7;
        if (hv_exists(self_hash, "_fields", keylen)) {
            SV* fields_ref;
            fields_ref = *(hv_fetch(self_hash, "_fields", keylen, 0));
            AV* fields_array;
            fields_array = (AV*)SvRV(fields_ref);
            I32* fields_maxi;
            fields_maxi = av_len(fields_array);
            
            if (fields_maxi >= 0) {
                SV* header_ref;
                keylen = 6;
                header_ref = *(hv_fetch(self_hash, "_chead", keylen, 0));
                
                uint8_t *tag_value;
                int type;
                
                int32_t tid;
                bam_header_t *header;
                uint32_t  *cigar;
                int cigar_loop;
                AV *cigar_avref;
                char *cigar_str;
                char *cigar_digits;
                int cigar_digits_length;
                int cigar_digits_i;
                int cigar_chars_total;
                
                char *cigar_op;
                int cigar_op_length;
                int raw_seq_length;
                int mapped_seq_length;
                
                char *seq;
                int seq_i;
                uint8_t *qual;
                int qual_i;
                char *qual_str;
                
                int i;
                char *field;
                STRLEN field_length;
                for (i = 0; i <= fields_maxi; i++) {
                    field = SvPV(*(av_fetch(fields_array, i, 0)), field_length);
                    
                    if (field_length > 2) {
                        if (strEQ(field, "QNAME")) {
                            hv_store(rh_hash, field, field_length, newSVpv(bam1_qname(b), 0), 0);
                        }
                        else if (strEQ(field, "FLAG")) {
                            hv_store(rh_hash, field, field_length, newSVuv(b->core.flag), 0);
                        }
                        else if (strEQ(field, "RNAME")) {
                            if (b->core.tid < 0) {
                                hv_store(rh_hash, field, field_length, newSVpv("*", 1), 0);
                            }
                            else {
                                header = (bam_header_t*)SvIV(SvRV(header_ref));
                                hv_store(rh_hash, field, field_length, newSVpv(header->target_name[b->core.tid], 0), 0);
                            }
                        }
                        else if (strEQ(field, "POS")) {
                            hv_store(rh_hash, field, field_length, newSVuv(b->core.pos + 1), 0);
                        }
                        else if (strEQ(field, "MAPQ")) {
                            hv_store(rh_hash, field, field_length, newSVuv(b->core.qual), 0);
                        }
                        else if (strEQ(field, "CIGAR")) {
                            if (b->core.n_cigar == 0) {
                                hv_store(rh_hash, field, field_length, newSVpv("*", 1), 0);
                            }
                            else {
                                cigar = bam1_cigar(b);
                                cigar_str = Newxz(cigar_str, b->core.n_cigar * 5, char);
                                cigar_chars_total = 0;
                                cigar_digits = Newxz(cigar_digits, 3, char);
                                for (cigar_loop = 0; cigar_loop < b->core.n_cigar; ++cigar_loop) {
                                    Renew(cigar_digits, 3, char);
                                    cigar_digits_length = sprintf(cigar_digits, "%i", cigar[cigar_loop]>>BAM_CIGAR_SHIFT);
                                    for (cigar_digits_i = 0; cigar_digits_i < cigar_digits_length; ++cigar_digits_i) {
                                        cigar_str[cigar_chars_total] = cigar_digits[cigar_digits_i];
                                        cigar_chars_total++;
                                    }
                                    
                                    cigar_str[cigar_chars_total] =  "MIDNSHP"[cigar[cigar_loop]&BAM_CIGAR_MASK];
                                    cigar_chars_total++;
                                }
                                
                                hv_store(rh_hash, field, field_length, newSVpv(cigar_str, cigar_chars_total), 0);
                                
                                Safefree(cigar_str);
                                Safefree(cigar_digits);
                            }
                        }
                        else if (strEQ(field, "MRNM")) {
                            if (b->core.mtid < 0) {
                                hv_store(rh_hash, field, field_length, newSVpv("*", 1), 0);
                            }
                            else {
                                header = (bam_header_t*)SvIV(SvRV(header_ref));
                                hv_store(rh_hash, field, field_length, newSVpv(header->target_name[b->core.mtid], 0), 0);
                            }
                        }
                        else if (strEQ(field, "MPOS")) {
                            hv_store(rh_hash, field, field_length, newSVuv(b->core.mpos + 1), 0);
                        }
                        else if (strEQ(field, "ISIZE")) {
                            hv_store(rh_hash, field, field_length, newSViv((int*)b->core.isize), 0);
                        }
                        else if (strEQ(field, "SEQ_LENGTH") || strEQ(field, "MAPPED_SEQ_LENGTH")) {
                            if (b->core.n_cigar == 0) {
                                if (b->core.l_qseq) {
                                    hv_store(rh_hash, field, field_length, newSVuv(b->core.l_qseq), 0);
                                }
                                else {
                                    hv_store(rh_hash, field, field_length, newSVuv(0), 0);
                                }
                            }
                            else {
                                cigar = bam1_cigar(b);
                                raw_seq_length = 0;
                                mapped_seq_length = 0;
                                for (cigar_loop = 0; cigar_loop < b->core.n_cigar; ++cigar_loop) {
                                    cigar_op_length = cigar[cigar_loop]>>BAM_CIGAR_SHIFT;
                                    cigar_op = "MIDNSHP"[cigar[cigar_loop]&BAM_CIGAR_MASK];
                                    
                                    if (cigar_op == 'S' || cigar_op == 'H' || cigar_op == 'I') {
                                        raw_seq_length = raw_seq_length + cigar_op_length;
                                    }
                                    else if (cigar_op == 'M') {
                                        raw_seq_length = raw_seq_length + cigar_op_length;
                                        mapped_seq_length = mapped_seq_length + cigar_op_length;
                                    }
                                }
                                
                                if (strEQ(field, "SEQ_LENGTH")) {
                                    hv_store(rh_hash, field, field_length, newSVuv(raw_seq_length), 0);
                                }
                                else {
                                    hv_store(rh_hash, field, field_length, newSVuv(mapped_seq_length), 0);
                                }
                            }
                        }
                        else if (strEQ(field, "SEQ")) {
                            if (b->core.l_qseq) {
                                seq = Newxz(seq, b->core.l_qseq + 1, char);
                                for (seq_i = 0; seq_i < b->core.l_qseq; ++seq_i) {
                                    seq[seq_i] = bam_nt16_rev_table[bam1_seqi(bam1_seq(b), seq_i)];
                                }
                                hv_store(rh_hash, field, field_length, newSVpv(seq, b->core.l_qseq), 0);
                                Safefree(seq);
                            }
                            else {
                                hv_store(rh_hash, field, field_length, newSVpv("*", 1), 0);
                            }
                        }
                        else if (strEQ(field, "QUAL")) {
                            if (b->core.l_qseq) {
                                qual = bam1_qual(b);
                                if (qual[0] != 0xff) {
                                    qual_str = Newxz(qual_str, b->core.l_qseq + 1, char);
                                    for (qual_i = 0; qual_i < b->core.l_qseq; ++qual_i) {
                                        qual_str[qual_i] = qual[qual_i] + 33;
                                    }
                                    hv_store(rh_hash, field, field_length, newSVpv(qual_str, b->core.l_qseq), 0);
                                    Safefree(qual_str);
                                }
                                else {
                                    hv_store(rh_hash, field, field_length, newSVpv("*", 1), 0);
                                }
                                
                            }
                            else {
                                hv_store(rh_hash, field, field_length, newSVpv("*", 1), 0);
                            }
                        }
                    }
                    else {
                        tag_value = bam_aux_get(b, field);
                        
                        if (tag_value != 0) {
                            type = *tag_value++;
                            switch (type) {
                                case 'c':
                                    hv_store(rh_hash, field, field_length, newSViv((int32_t)*(int8_t*)tag_value), 0);
                                    break;
                                case 'C':
                                    hv_store(rh_hash, field, field_length, newSViv((int32_t)*(uint8_t*)tag_value), 0);
                                    break;
                                case 's':
                                    hv_store(rh_hash, field, field_length, newSViv((int32_t)*(int16_t*)tag_value), 0);
                                    break;
                                case 'S':
                                    hv_store(rh_hash, field, field_length, newSViv((int32_t)*(uint16_t*)tag_value), 0);
                                    break;
                                case 'i':
                                    hv_store(rh_hash, field, field_length, newSViv(*(int32_t*)tag_value), 0);
                                    break;
                                case 'I':
                                    hv_store(rh_hash, field, field_length, newSViv((int32_t)*(uint32_t*)tag_value), 0);
                                    break;
                                case 'f':
                                    hv_store(rh_hash, field, field_length, newSVnv(*(float*)tag_value), 0);
                                    break;
                                case 'A':
                                    hv_store(rh_hash, field, field_length, newSVpv((char*)tag_value, 1), 0);
                                    break;
                                case 'Z':
                                case 'H':
                                    hv_store(rh_hash, field, field_length, newSVpv((char*)tag_value, 0), 0);
                                    break;
                            }
                        }
                        else {
                            hv_store(rh_hash, field, field_length, newSVpv("*", 1), 0);
                        }
                    }
                }
            }
        }
        
        Inline_Stack_Push(sv_2mortal(newSVuv(1)));
    }
    else {
        Inline_Stack_Push(sv_2mortal(newSVuv(0)));
    }
    Inline_Stack_Done;
}

END_C

1;
