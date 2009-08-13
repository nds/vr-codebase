=head1 NAME

VertRes::Utils::Hierarchy - hierarchy utility functions

=head1 SYNOPSIS

use VertRes::Utils::Hierarchy;

my $hierarchy_util = VertRes::Utils::Hierarchy->new();

$hierarchy_util->;

=head1 DESCRIPTION

General utility functions for working on or with team145's data/mapping/release
hierarchy directory structure.

=head1 AUTHOR

Sendu Bala: bix@sendu.me.uk

=cut

package VertRes::Utils::Hierarchy;

use strict;
use warnings;
use VertRes::IO;
use File::Basename;
use File::Spec;
use File::Path;
use VertRes::Parser::sequence_index;
use VertRes::Utils::Sam;

use base qw(VertRes::Base);

our %project_to_srp = ('Exon-CEU' => 'SRP000033',
                       'Exon-CHB' => 'SRP000033',
                       'Exon-DEN' => 'SRP000033',
                       'Exon-JPT' => 'SRP000033',
                       'Exon-LWK' => 'SRP000033',
                       'Exon-TSI' => 'SRP000033',
                       'Exon-YRI' => 'SRP000033',
                       'LowCov-CEU' => 'SRP000031',
                       'LowCov-CHB' => 'SRP000031',
                       'LowCov-JPT' => 'SRP000031',
                       'LowCov-YRI' => 'SRP000031',
                       'Trio-CEU' => 'SRP000032',
                       'Trio-YRI' => 'SRP000032');

our %platform_aliases = (ILLUMINA => 'SLX',
                         LS454 => '454');

=head2 new

 Title   : new
 Usage   : my $obj = VertRes::Utils::Hierarchy->new();
 Function: Create a new VertRes::Utils::Hierarchy object.
 Returns : VertRes::Utils::Hierarchy object
 Args    : n/a

=cut

sub new {
    my ($class, @args) = @_;
    
    my $self = $class->SUPER::new(@args);
    
    return $self;
}

=head2 parse_lane

 Title   : parse_lane
 Usage   : my %info = $obj->parse_lane('/path/to/lane');
 Function: Extract information about a lane based on its location in the
           hierarchy directory structure.
 Returns : hash with keys study, sample, platform, library and lane.
 Args    : a directory path

=cut

sub parse_lane {
    my ($self, $lane_path) = @_;
    
    my @dirs = File::Spec->splitdir($lane_path);
    @dirs >= 5 || $self->throw("lane path '$lane_path' wasn't valid");
    
    my ($study, $sample, $platform, $library, $lane) = @dirs[-5..-1];
    
    return (study => $study, sample => $sample, platform => $platform,
            library => $library, lane => $lane);
}

=head2 check_lanes_vs_sequence_index

 Title   : check_lanes_vs_sequence_index
 Usage   : my $ok = $obj->check_lanes_vs_sequence_index(['/lane/paths', ...],
                                                        'sequence.index');
 Function: Check that the given lanes reside in the correct part of the
           hierarchy by checking the information in the sequence.index file.
 Returns : boolean (true if all lanes agree with the sequence index)
 Args    : reference to a list of lane paths to check, sequence.index filename

=cut

sub check_lanes_vs_sequence_index {
    my ($self, $lanes, $sequence_index) = @_;
    
    my $sip = VertRes::Parser::sequence_index->new(file => $sequence_index);
    
    my $all_ok = 1;
    foreach my $lane_path (@{$lanes}) {
        my %lane_info = $self->parse_lane($lane_path);
        my $lane_id = $lane_info{lane};
        
        # check this lane is even in the sequence.index; $sip will warn if not
        my $sample_name = $sip->lane_info($lane_id, 'sample_name');
        unless ($sample_name) {
            $all_ok = 0;
            next;
        }
        
        # check this lane hasn't been withdrawn
        my $withdrawn = $sip->lane_info($lane_id, 'WITHDRAWN');
        if ($withdrawn) {
            $self->warn("");
            $all_ok = 0;
            next;
        }
        
        # study swaps
        my $given_study = $project_to_srp{$lane_info{study}} || $lane_info{study};
        my $study = $sip->lane_info($lane_id, 'study_id');
        unless ($study eq $given_study) {
            $self->warn("study swap: $study vs $given_study for $lane_id ($lane_path)");
            $all_ok = 0;
        }
        
        # sample swaps
        unless ($sample_name eq $lane_info{sample}) {
            $self->warn("sample swap: $sample_name vs $lane_info{sample} for $lane_id ($lane_path)");
            $all_ok = 0;
        }
        
        # platform swaps
        my $platform = $sip->lane_info($lane_id, 'INSTRUMENT_PLATFORM');
        unless ($platform eq $lane_info{platform} || $platform_aliases{$platform} eq $lane_info{platform}) {
            $self->warn("platform swap: $platform vs $lane_info{platform} for $lane_id ($lane_path)");
            $all_ok = 0;
        }
        
        # library swaps
        my $library = $sip->lane_info($lane_id, 'LIBRARY_NAME');
        unless ($library eq $lane_info{library}) {
            $self->warn("library swap: $library vs $lane_info{library} for $lane_id ($lane_path)");
            $all_ok = 0;
        }
    }
    
    return $all_ok;
}

=head2 create_release_hierarchy

 Title   : create_release_hierarchy
 Usage   : my $ok = $obj->create_release_hierarchy(\@abs_lane_paths,
                                                   '/path/to/release');
 Function: Given a list of absolute paths to mapped lanes in a mapping
           hierarchy, creates a release hierarchy with mapped bams symlinked
           across.
           NB: You should probably call check_lanes_vs_sequence_index() on the
           the input lanes beforehand.
 Returns : list of absolute paths to the bam symlinks in the created release
           hierarchy
 Args    : reference to a list of mapped lane paths, base path you want to
           build the release hierarchy in

=cut

sub create_release_hierarchy {
    my ($self, $lane_paths, $release_dir) = @_;
    
    unless (-d $release_dir) {
        mkdir($release_dir) || $self->throw("Unable to create base release directory: $!");
    }
    my $io = VertRes::IO->new();
    
    my @all_linked_bams;
    
    foreach my $lane_path (@{$lane_paths}) {
        # setup release lane
        my @dirs = File::Spec->splitdir($lane_path);
        @dirs >= 5 || $self->throw("lane path '$lane_path' wasn't valid");
        my $release_lane_path = $io->catfile($release_dir, @dirs[-5..-1]);
        mkpath($release_lane_path);
        -d $release_lane_path || $self->throw("Unable to make release lane '$release_lane_path'");
        
        # symlink bams
        my @linked_bams;
        foreach my $ended ('pe', 'se') {
            my $bam_file = "${ended}_raw.sorted.bam";
            my $source = $io->catfile($lane_path, $bam_file);
            
            if (-s $source) {
                my $destination = $io->catfile($release_lane_path, $bam_file);
                symlink($source, $destination) || $self->throw("Couldn't symlink $source -> $destination");
                push(@linked_bams, $destination);
            }
        }
        
        # old mapping pipeline didn't create pe/se bams
        unless (@linked_bams) {
            my $legacy_bam_file = 'raw.sorted.bam';
            my $source = $io->catfile($lane_path, $legacy_bam_file);
            if (-s $source) {
                # figure out if it was generated from paired or single ended reads
                my $meta_file = $io->catfile($lane_path, 'meta.info');
                if (-s $meta_file) {
                    $io->file($meta_file);
                    my $fh = $io->fh;
                    my %reads;
                    while (<$fh>) {
                        if (/^read(\d)/) {
                            $reads{$1} = 1;
                        }
                    }
                    $io->close;
                    
                    my $ended;
                    if ($reads{1} && $reads{2}) {
                        $ended = 'pe';
                    }
                    elsif ($reads{0}) {
                        $ended = 'se';
                    }
                    else {
                        $self->throw("Couldn't determine if reads were single or paired end in lane '$lane_path'");
                    }
                    
                    my $bam_file = "${ended}_raw.sorted.bam";
                    my $destination = $io->catfile($release_lane_path, $bam_file);
                    symlink($source, $destination) || $self->throw("Couldn't symlink $source -> $destination");
                    push(@linked_bams, $destination);
                }
            }
        }
        
        unless (@linked_bams) {
            $self->throw("Mapping lane '$lane_path' contained no linkable bam files!");
        }
        
        push(@all_linked_bams, @linked_bams);
    }
    
    return @all_linked_bams;
}

1;