package Tephra::Classify::LTRFams;

use 5.010;
use Moose;
use MooseX::Types::Path::Class;
use Statistics::Descriptive;
use Sort::Naturally;
use Number::Range;
use File::Spec;
use File::Find;
use File::Basename;
use Bio::DB::HTS::Kseq;
use Bio::DB::HTS::Faidx;
use Bio::GFF3::LowLevel qw(gff3_parse_feature);
use List::MoreUtils     qw(indexes any);
use List::Util          qw(min max);
use Time::HiRes         qw(gettimeofday);
use File::Path          qw(make_path);
use Parallel::ForkManager;
use Cwd;
use Carp 'croak';
use Try::Tiny;
use Tephra::Config::Exe;
#use Data::Dump::Color;
use namespace::autoclean;

with 'Tephra::Role::GFF',
     'Tephra::Role::Util';

=head1 NAME

Tephra::Classify::LTRFams - Classify LTR retrotransposons into families

=head1 VERSION

Version 0.03.8

=cut

our $VERSION = '0.03.8';
$VERSION = eval $VERSION;

=head1 SYNOPSIS

    use Tephra::Classify::LTRFams;

    my $genome  = 'genome.fasta';     # genome sequences in FASTA format
    my $outdir  = 'ltr_families_out'; # directory to place the results
    my $threads = 12;                 # the number of threads to use for parallel processing
    my $gyp_gff = 'gypsy_ltrs.gff3';  # GFF file generated by Tephra::Classify::LTRSFams
    my $cop_gff = 'copia_ltrs.gff3';  # GFF file generated by Tephra::Classify::LTRSFams

    my $classify_fams_obj = Tephra::Classify::LTRFams->new(
        genome   => $genome,
        outdir   => $outdir,
        threads  => $threads,
    );

    my $gyp_dir = $classify_fams_obj->extract_features($gyp_gff);
    my $gyp_clusters = $classify_fams_obj->cluster_features($gyp_dir);
    my $gyp_fams = $classify_fams_obj->parse_clusters($gyp_clusters);
    
    my $cop_dir = $classify_fams_obj->extract_features($cop_gff);
    my $cop_clusters = $classify_fams_obj->cluster_features($cop_dir);
    my $cop_fams = $classify_fams_obj->parse_clusters($cop_clusters);

    my %outfiles;
    @outfiles{keys %$_} = values %$_ for ($gyp_fams, $cop_fams);
    $classify_fams_obj->combine_families(\%outfiles);

=cut

has genome => (
    is       => 'ro',
    isa      => 'Path::Class::File',
    required => 1,
    coerce   => 1,
);

has outdir => (
    is       => 'ro',
    isa      => 'Path::Class::Dir',
    required => 1,
    coerce   => 1,
);

has threads => (
    is        => 'ro',
    isa       => 'Int',
    predicate => 'has_threads',
    lazy      => 1,
    default   => 1,
);

#
# methods
#
sub extract_features {
    my $self = shift;
    my $fasta  = $self->genome;
    my $dir    = $self->outdir;
    my ($infile) = @_;
    
    my $index = $self->index_ref($fasta);

    my ($name, $path, $suffix) = fileparse($infile, qr/\.[^.]*/);
    my $type = ($name =~ /(?:gypsy|copia|unclassified)$/i);
    die "\nERROR: Unexpected input. Should match /gypsy|copia|unclassified$/i. Exiting."
	unless defined $type;

    my $resdir = File::Spec->catdir($dir, $name);
    unless ( -d $resdir ) {
	make_path( $resdir, {verbose => 0, mode => 0771,} );
    }
    
    my $comp = File::Spec->catfile($resdir, $name.'_complete.fasta');
    my $ppts = File::Spec->catfile($resdir, $name.'_ppt.fasta');
    my $pbs  = File::Spec->catfile($resdir, $name.'_pbs.fasta');
    my $five_pr_ltrs  = File::Spec->catfile($resdir, $name.'_5prime-ltrs.fasta');
    my $three_pr_ltrs = File::Spec->catfile($resdir, $name.'_3prime-ltrs.fasta');

    open my $allfh, '>>', $comp or die "\nERROR: Could not open file: $comp\n";
    open my $pptfh, '>>', $ppts or die "\nERROR: Could not open file: $ppts\n";
    open my $pbsfh, '>>', $pbs or die "\nERROR: Could not open file: $pbs\n";
    open my $fivefh, '>>', $five_pr_ltrs or die "\nERROR: Could not open file: $five_pr_ltrs\n";
    open my $threfh, '>>', $three_pr_ltrs or die "\nERROR: Could not open file: $three_pr_ltrs\n";

    open my $gffio, '<', $infile or die "\nERROR: Could not open file: $infile\n";

    my (%feature, %ltrs, %coord_map, %seen);
    while (my $line = <$gffio>) {
	chomp $line;
	next if $line =~ /^#/;
	my $feature = gff3_parse_feature($line);

	if ($feature->{type} eq 'LTR_retrotransposon') {
	    my $elem_id = @{$feature->{attributes}{ID}}[0];
	    my ($start, $end) = @{$feature}{qw(start end)};
	    my $key = join "||", $elem_id, $start, $end;
	    $ltrs{$key}{'full'} = join "||", @{$feature}{qw(seq_id type start end)};
	    $coord_map{$elem_id} = join "||", @{$feature}{qw(seq_id start end)};
	}
	if ($feature->{type} eq 'long_terminal_repeat') {
	    my $parent = @{$feature->{attributes}{Parent}}[0];
	    my ($seq_id, $pkey) = $self->get_parent_coords($parent, \%coord_map);
	    if ($seq_id eq $feature->{seq_id}) {
		my ($seq_id, $type, $start, $end, $strand) = 
		    @{$feature}{qw(seq_id type start end strand)};
		$strand //= '?';
		my $ltrkey = join "||", $seq_id, $type, $start, $end, $strand;
		push @{$ltrs{$pkey}{'ltrs'}}, $ltrkey unless exists $seen{$ltrkey};
		$seen{$ltrkey} = 1;
	    }
	}
	elsif ($feature->{type} eq 'primer_binding_site') {
	    my $name = $feature->{attributes}{trna};
	    my $parent = @{$feature->{attributes}{Parent}}[0];
	    my ($seq_id, $pkey) = $self->get_parent_coords($parent, \%coord_map);
            if ($seq_id eq $feature->{seq_id}) {
		$ltrs{$pkey}{'pbs'} =
		    join "||", @{$feature}{qw(seq_id type)}, $name, @{$feature}{qw(start end)};
	    }
	}
	elsif ($feature->{type} eq 'protein_match') {
	    my $name = @{$feature->{attributes}{name}}[0];
	    my $parent = @{$feature->{attributes}{Parent}}[0];
	    my ($seq_id, $pkey) = $self->get_parent_coords($parent, \%coord_map);
            if ($seq_id eq $feature->{seq_id}) {
		my $pdomkey = join "||", @{$feature}{qw(seq_id type)}, $name, @{$feature}{qw(start end strand)};
		push @{$ltrs{$pkey}{'pdoms'}{$name}}, $pdomkey unless exists $seen{$pdomkey};
		$seen{$pdomkey} = 1;
	    }
	}
	elsif ($feature->{type} eq 'RR_tract') {
	    my $parent = @{$feature->{attributes}{Parent}}[0];
	    my ($seq_id, $pkey) = $self->get_parent_coords($parent, \%coord_map);
            if ($seq_id eq $feature->{seq_id}) {
		$ltrs{$pkey}{'ppt'} =
		    join "||", @{$feature}{qw(seq_id type start end)};
	    }
	}
    }
    close $gffio;

    my (%pdoms, %seen_pdoms);
    my $ltrct = 0;
    for my $ltr (sort keys %ltrs) {
	my ($element, $rstart, $rend) = split /\|\|/, $ltr;
	# full element
	my ($source, $prim_tag, $fstart, $fend) = split /\|\|/, $ltrs{$ltr}{'full'};
	$self->subseq($index, $source, $element, $fstart, $fend, $allfh);

	# pbs
	if ($ltrs{$ltr}{'pbs'}) {
	    my ($pbssource, $pbstag, $trna, $pbsstart, $pbsend) = split /\|\|/, $ltrs{$ltr}{'pbs'};
	    $self->subseq($index, $pbssource, $element, $pbsstart, $pbsend, $pbsfh);
	}

	# ppt
	if ($ltrs{$ltr}{'ppt'}) {
	    my ($pptsource, $ppttag, $pptstart, $pptend) = split /\|\|/, $ltrs{$ltr}{'ppt'};
	    $self->subseq($index, $source, $element, $pptstart, $pptend, $pptfh);
	}

	for my $ltr_repeat (@{$ltrs{$ltr}{'ltrs'}}) {
	    my ($src, $ltrtag, $s, $e, $strand) = split /\|\|/, $ltr_repeat;
	    if ($ltrct) {
		$self->subseq($index, $src, $element, $s, $e, $fivefh);
		$ltrct = 0;
	    }
	    else {
		$self->subseq($index, $src, $element, $s, $e, $threfh);
		$ltrct++;
	    }
	}

	if ($ltrs{$ltr}{'pdoms'}) {
	    for my $model_name (keys %{$ltrs{$ltr}{'pdoms'}}) {
		for my $ltr_repeat (@{$ltrs{$ltr}{'pdoms'}{$model_name}}) {
		    my ($src, $pdomtag, $name, $s, $e, $str) = split /\|\|/, $ltr_repeat;
                    #"Ha10||protein_match||UBN2||132013916||132014240|+",
		    next if $model_name =~ /transpos(?:ase)?|mule|(?:dbd|dde)?_tnp_(?:hat)?|duf4216/i; 
		    # The above is so we do not classify elements based domains derived from or belonging to DNA transposons
		    push @{$pdoms{$src}{$element}{$model_name}}, join "||", $s, $e, $str;
		}
	    }
	}
    }
    close $allfh;
    close $pptfh;
    close $pbsfh;
    close $fivefh;
    close $threfh;

    ## This is where we merge overlapping hits in a chain and concatenate non-overlapping hits
    ## to create a single domain sequence for each element
    for my $src (keys %pdoms) {
	for my $element (keys %{$pdoms{$src}}) {
	    my ($pdom_s, $pdom_e, $str);
	    for my $pdom_type (keys %{$pdoms{$src}{$element}}) {
		my (%lrange, %seqs, $union);
		my $pdom_file = File::Spec->catfile($resdir, $pdom_type.'_pdom.fasta');
		open my $fh, '>>', $pdom_file or die "\nERROR: Could not open file: $pdom_file\n";
		for my $split_dom (@{$pdoms{$src}{$element}{$pdom_type}}) {
		    ($pdom_s, $pdom_e, $str) = split /\|\|/, $split_dom;
		    push @{$lrange{$src}{$element}{$pdom_type}}, "$pdom_s..$pdom_e";
		}
		
		if (@{$lrange{$src}{$element}{$pdom_type}} > 1) {
		    {
			no warnings; # Number::Range warns on EVERY single interger that overlaps
			my $range = Number::Range->new(@{$lrange{$src}{$element}{$pdom_type}});
			$union = $range->range;
		    }
		            
		    for my $r (split /\,/, $union) {
			my ($ustart, $uend) = split /\.\./, $r;
			my $seq = $self->subseq_pdoms($index, $src, $ustart, $uend);
			my $k = join "_", $ustart, $uend;
			$seqs{$k} = $seq;
		    }
		            
		    $self->concat_pdoms($src, $element, \%seqs, $fh);
		}
		else {
		    my ($nustart, $nuend, $str) = split /\|\|/, @{$pdoms{$src}{$element}{$pdom_type}}[0];
		    $self->subseq($index, $src, $element, $nustart, $nuend, $fh);
		}
		close $fh;
		%seqs   = ();
		%lrange = ();
		unlink $pdom_file if ! -s $pdom_file;
	    }
	}
    }

    for my $file ($comp, $ppts, $pbs, $five_pr_ltrs, $three_pr_ltrs) {
	unlink $file if ! -s $file;
    }

    return $resdir
}

sub subseq_pdoms {
    my $self = shift;
    my ($index, $loc, $start, $end) = @_;

    my $location = "$loc:$start-$end";
    my ($seq, $length) = $index->get_sequence($location);
    croak "\nERROR: Something went wrong. This is a bug, please report it.\n"
	unless $length;
    return $seq;
}

sub concat_pdoms {
    my $self = shift;
    my ($src, $elem, $seqs, $fh_out) = @_;
    my @ranges = map { split /\_/, $_ } keys %$seqs;
    my $start  = min(@ranges);
    my $end    = max(@ranges);
    my $id     = join "_", $elem, $src, $start, $end;

    my $concat_seq;
    for my $seq (values %$seqs) {
	$concat_seq .= $seq;
    }

    $concat_seq =~ s/.{60}\K/\n/g;
    say $fh_out join "\n", ">$id", $concat_seq;
}

sub collect_feature_args {
    my $self = shift;
    my ($dir) = @_;
    my (@fiveltrs, @threeltrs, @ppt, @pbs, @pdoms, %vmatch_args);
    find( sub { push @fiveltrs, $File::Find::name if -f and /5prime-ltrs.fasta$/ }, $dir);
    find( sub { push @threeltrs, $File::Find::name if -f and /3prime-ltrs.fasta$/ }, $dir);
    find( sub { push @ppt, $File::Find::name if -f and /ppts.fasta$/ }, $dir);
    find( sub { push @pbs, $File::Find::name if -f and /pbs.fasta$/ }, $dir);
    find( sub { push @pdoms, $File::Find::name if -f and /pdom.fasta$/ }, $dir);

    # ltr
    my $ltr5name = File::Spec->catfile($dir, 'dbcluster-5primeseqs');
    my $fiveargs = "-qspeedup 2 -dbcluster 80 20 $ltr5name -p -d -seedlength 30 ";
    $fiveargs .= "-exdrop 7 -l 80 -showdesc 0 -sort ld -best 10000 -identity 80";
    $vmatch_args{fiveltr} = { seqs => \@fiveltrs, args => $fiveargs };

    my $ltr3name  = File::Spec->catfile($dir, 'dbcluster-3primeseqs');
    my $threeargs = "-qspeedup 2 -dbcluster 80 20 $ltr3name -p -d -seedlength 30 ";
    $threeargs .= "-exdrop 7 -l 80 -showdesc 0 -sort ld -best 10000 -identity 80";
    $vmatch_args{threeltr} = { seqs => \@threeltrs, args => $threeargs };

    # pbs/ppt
    my $pbsname = File::Spec->catfile($dir, 'dbcluster-pbs');
    my $pbsargs = "-dbcluster 90 90 $pbsname -p -d -seedlength 5 -exdrop 2 ";
    $pbsargs .= "-l 3 -showdesc 0 -sort ld -best 10000";
    $vmatch_args{pbs} = { seqs => \@pbs, args => $pbsargs, prefixlen => 1 };

    my $pptname = File::Spec->catfile($dir, 'dbcluster-ppt');
    my $pptargs = "-dbcluster 90 90 $pptname -p -d -seedlength 5 -exdrop 2 ";
    $pptargs .= "-l 3 -showdesc 0 -sort ld -best 10000";
    $vmatch_args{ppt} = { seqs => \@ppt, args => $pptargs, prefixlen => 5 };

    # pdoms
    my $pdomname = File::Spec->catfile($dir, 'dbcluster-pdoms');
    my $pdomargs = "-qspeedup 2 -dbcluster 80 80 $pdomname -p -d -seedlength 30 -exdrop 3 ";
    $pdomargs .= "-l 40 -showdesc 0 -sort ld -best 100";
    $vmatch_args{pdoms} = { seqs => \@pdoms, args => $pdomargs };

    return \%vmatch_args;
}

sub cluster_features {
    my $self = shift;
    my $threads = $self->threads;
    my ($dir) = @_;

    my $args = $self->collect_feature_args($dir);
    $self->_remove_singletons($args);

    my $t0 = gettimeofday();
    my $doms = 0;
    my %reports;
    my $outfile = File::Spec->catfile($dir, 'all_vmatch_reports.txt');
    my $logfile = File::Spec->catfile($dir, 'all_vmatch_reports.log');
    open my $out, '>>', $outfile or die "\nERROR: Could not open file: $outfile\n";
    open my $log, '>>', $logfile or die "\nERROR: Could not open file: $logfile\n";
    
    my $pm = Parallel::ForkManager->new($threads);
    local $SIG{INT} = sub {
        $log->warn("Caught SIGINT; Waiting for child processes to finish.");
        $pm->wait_all_children;
        exit 1;
    };

    $pm->run_on_finish( sub { my ($pid, $exit_code, $ident, $exit_signal, $core_dump, $data_ref) = @_;
			      for my $bl (sort keys %$data_ref) {
				  open my $report, '<', $bl or die "\nERROR: Could not open file: $bl\n";
				  print $out $_ while <$report>;
				  close $report;
				  unlink $bl;
			      }
			      my $t1 = gettimeofday();
			      my $elapsed = $t1 - $t0;
			      my $time = sprintf("%.2f",$elapsed/60);
			      say $log basename($ident),
			      " just finished with PID $pid and exit code: $exit_code in $time minutes";
			} );

    for my $type (keys %$args) {
	for my $db (@{$args->{$type}{seqs}}) {
	    $doms++;
	    $pm->start($db) and next;
	    $SIG{INT} = sub { $pm->finish };
	    my $vmrep = $self->process_cluster_args($args, $type, $db);
	    $reports{$vmrep} = 1;

	    $pm->finish(0, \%reports);
	}
    }

    $pm->wait_all_children;
    close $out;

    my $t2 = gettimeofday();
    my $total_elapsed = $t2 - $t0;
    my $final_time = sprintf("%.2f",$total_elapsed/60);

    say $log "\n========> Finished running vmatch on $doms domains in $final_time minutes";
    close $log;

    return $outfile;
}

sub process_cluster_args {
    my $self = shift;
    my ($args, $type, $db) = @_;

    my ($name, $path, $suffix) = fileparse($db, qr/\.[^.]*/);
    my $index = File::Spec->catfile($path, $name.'.index');
    my $vmrep = File::Spec->catfile($path, $name.'_vmatch-out.txt');
    my $log   = File::Spec->catfile($path, $name.'_vmatch-out.log');;

    my $mkvtreecmd = "mkvtree -db $db -dna -indexname $index -allout -v -pl ";
    if (defined $args->{$type}{prefixlen}) {
	$mkvtreecmd .= "$args->{$type}{prefixlen} ";
    }
    $mkvtreecmd .= "2>&1 > $log";
    my $vmatchcmd  = "vmatch $args->{$type}{args} $index > $vmrep";
    $self->run_cmd($mkvtreecmd);
    $self->run_cmd($vmatchcmd);
    unlink glob "$index*";
    unlink glob "$path/*.match";

    return $vmrep;
}

sub subseq {
    my $self = shift;
    my ($index, $loc, $elem, $start, $end, $out) = @_;

    my $location = "$loc:$start-$end";
    my ($seq, $length) = $index->get_sequence($location);
    croak "\nERROR: Something went wrong. This is a bug, please report it.\n"
	unless $length;

    my $id = join "_", $elem, $loc, $start, $end;

    $seq =~ s/.{60}\K/\n/g;
    say $out join "\n", ">$id", $seq;
}

sub parse_clusters {
    my $self = shift;
    my ($clsfile) = @_;
    my $genome = $self->genome;
    
    my ($name, $path, $suffix) = fileparse($genome, qr/\.[^.]*/);
    if ($name =~ /(\.fa.*)/) {
	$name =~ s/$1//;
    }

    my ($cname, $cpath, $csuffix) = fileparse($clsfile, qr/\.[^.]*/);
    my $dir  = basename($cpath);
    my ($sf) = ($dir =~ /_(\w+)$/);
    my $sfname;
    $sfname = 'RLG' if $sf =~ /gypsy/i;
    $sfname = 'RLC' if $sf =~ /copia/i;
    $sfname = 'RLX' if $sf =~ /unclassified/i;

    my @compfiles;
    find( sub { push @compfiles, $File::Find::name if /complete.fasta$/ }, $cpath );
    my $ltrfas = shift @compfiles;
    my $seqstore = $self->_store_seq($ltrfas);

    my (%cls, %all_seqs, %all_pdoms, $clusnum, $dom);
    open my $in, '<', $clsfile or die "\nERROR: Could not open file: $clsfile\n";

    while (my $line = <$in>) {
	chomp $line;
	if ($line =~ /^# args=/) {
	    my ($type) = ($line =~ /\/(\S+).index\z/);
	    $dom = basename($type);
	    $dom =~ s/${name}_//;
	    $dom =~ s/_pdom//;
	    $all_pdoms{$dom} = 1;
	}
	next if $line =~ /^# \d+/;
	if ($line =~ /^(\d+):/) {
	    $clusnum = $1;
	}
	elsif ($line =~ /^\s+(\S+)/) {
	    my $element = $1;
	    $element =~ s/_\d+-?_?\d+$//;
	    push @{$cls{$dom}{$clusnum}}, $element;
	}
    }
    close $in;

    my (%elem_sorted, %multi_cluster_elem);
    for my $pdom (keys %cls) {
	for my $clsnum (keys %{$cls{$pdom}}) {
	    for my $elem (@{$cls{$pdom}{$clsnum}}) {
		push @{$elem_sorted{$elem}}, { $pdom => $clsnum };
	    }
	}
    }

    my %dom_orgs;
    for my $element (keys %elem_sorted) {
	my $string;
	my %pdomh;
	@pdomh{keys %$_} = values %$_ for @{$elem_sorted{$element}};
	for my $pdom (nsort keys %cls) {
	    if (exists $pdomh{$pdom}) {
		$string .= length($string) ? "|$pdomh{$pdom}" : $pdomh{$pdom};
	    }
	    else {
		$string .= length($string) ? "|N" : "N";
	    }
	}
	push @{$dom_orgs{$string}}, $element;
	undef $string;
    }

    my $idx = 0;
    my (%fastas, %annot_ids);
    for my $str (reverse sort { @{$dom_orgs{$a}} <=> @{$dom_orgs{$b}} } keys %dom_orgs) {
	my $famfile = $sf."_family$idx".".fasta";
	my $outfile = File::Spec->catfile($cpath, $famfile);
	open my $out, '>>', $outfile or die "\nERROR: Could not open file: $outfile\n";
	for my $elem (@{$dom_orgs{$str}}) {
	    if (exists $seqstore->{$elem}) {
		my $coordsh = $seqstore->{$elem};
		my $coords  = (keys %$coordsh)[0];
		$seqstore->{$elem}{$coords} =~ s/.{60}\K/\n/g;
		say $out join "\n", ">$sfname"."_family$idx"."_$elem"."_$coords", $seqstore->{$elem}{$coords};
		delete $seqstore->{$elem};
		$annot_ids{$elem} = $sfname."_family$idx";
	    }
	    else {
		die "\nERROR: $elem not found in store. Exiting.";
	    }
	}
	close $out;
	$idx++;
	$fastas{$outfile} = 1;
    }
    $idx = 0;

    if (%$seqstore) {
	my $famxfile = $sf.'_singleton_families.fasta';
	my $xoutfile = File::Spec->catfile($cpath, $famxfile);
	open my $outx, '>', $xoutfile or die "\nERROR: Could not open file: $xoutfile\n";
	for my $k (nsort keys %$seqstore) {
	    my $coordsh = $seqstore->{$k};
	    my $coords  = (keys %$coordsh)[0];
	    $seqstore->{$k}{$coords} =~ s/.{60}\K/\n/g;
	    say $outx join "\n", ">$sfname"."_singleton_family$idx"."_$k"."_$coords", $seqstore->{$k}{$coords};
	    $annot_ids{$k} = $sfname."_singleton_family$idx";
	    $idx++;
	}
	close $outx;
	$fastas{$xoutfile} = 1;
    }

    return (\%fastas, \%annot_ids);
}

sub combine_families {
    my ($self) = shift;
    my ($outfiles) = @_;
    my $genome = $self->genome;
    my $outdir = $self->outdir;
    
    my ($name, $path, $suffix) = fileparse($genome, qr/\.[^.]*/);
    my $outfile = File::Spec->catfile($outdir, $name."_combined_LTR_families.fasta");
    open my $out, '>', $outfile or die "\nERROR: Could not open file: $outfile\n";

    for my $file (nsort keys %$outfiles) {
	my $kseq = Bio::DB::HTS::Kseq->new($file);
	my $iter = $kseq->iterator();
	while (my $seqobj = $iter->next_seq) {
	    my $id  = $seqobj->name;
	    my $seq = $seqobj->seq;
	    $seq =~ s/.{60}\K/\n/g;
	    say $out join "\n", ">$id", $seq;
	}
    }
    close $outfile;
}

sub annotate_gff {
    my $self = shift;
    my ($annot_ids, $gff) = @_;
    my $outdir = $self->outdir;

    my ($name, $path, $suffix) = fileparse($gff, qr/\.[^.]*/);
    my $outfile = File::Spec->catfile($outdir, $name.'_families.gff3');
    open my $in, '<', $gff or die "\nERROR: Could not open file: $gff\n";
    open my $out, '>', $outfile or die "\nERROR: Could not open file: $outfile\n";

    while (my $line = <$in>) {
	chomp $line;
	if ($line =~ /^#/) {
	    say $out $line;
	}
	else {
	    my @f = split /\t/, $line;
	    if ($f[2] eq 'LTR_retrotransposon') {
		my ($id) = ($f[8] =~ /ID=(LTR_retrotransposon\d+);/);
		my $key  = $id."_$f[0]";
		if (exists $annot_ids->{$key}) {
		    my $family = $annot_ids->{$key};
		    $f[8] =~ s/ID=$id\;/ID=$id;family=$family;/;
		    say $out join "\t", @f;
		}
		else {
		    say $out join "\t", @f;
		}
	    }
	    else {
		say $out join "\t", @f;
	    }
	}
    }
    close $in;
    close $out;
}

sub _store_seq {
    my $self = shift;
    my ($file) = @_;

    my %hash;
    my $kseq = Bio::DB::HTS::Kseq->new($file);
    my $iter = $kseq->iterator();
    while (my $seqobj = $iter->next_seq) {
	my $id = $seqobj->name;
	my ($coords) = ($id =~ /_(\d+_\d+)$/);
	$id =~ s/_$coords//;
	my $seq = $seqobj->seq;
	$hash{$id} = { $coords => $seq };
    }

    return \%hash;
}

sub _remove_singletons {
    my $self = shift;
    my ($args) = @_;

    my @singles;
    my ($index, $seqct) = (0, 0);
    for my $type (keys %$args) {
	delete $args->{$type} if ! @{$args->{$type}{seqs}};
	for my $db (@{$args->{$type}{seqs}}) {
	    my $kseq = Bio::DB::HTS::Kseq->new($db);
	    my $iter = $kseq->iterator();
	    while (my $seqobj = $iter->next_seq) { $seqct++ if defined $seqobj->seq; }
	    if ($seqct < 2) {
		push @singles, $index;
		unlink $db;
	    }
	    $index++;
	    $seqct = 0;
	}

	if (@{$args->{$type}{seqs}}) {
	    if (@singles > 1) {
		for (@singles) {
		    splice @{$args->{$type}{seqs}}, $_, 1;
		    @singles = map { $_ - 1 } @singles; # array length is changing after splice so we need to adjust offsets
		}
	    }
	    else {
		splice @{$args->{$type}{seqs}}, $_, 1 for @singles;
	    }
	}
	else {
	    delete $args->{$type};
	}
	$index = 0;
	@singles = ();
    }
}

=head1 AUTHOR

S. Evan Staton, C<< <statonse at gmail.com> >>

=head1 BUGS

Please report any bugs or feature requests through the project site at 
L<https://github.com/sestaton/tephra/issues>. I will be notified,
and there will be a record of the issue. Alternatively, I can also be 
reached at the email address listed above to resolve any questions.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Tephra::Classify::LTRFams


=head1 LICENSE AND COPYRIGHT

Copyright (C) 2015- S. Evan Staton

This program is distributed under the MIT (X11) License, which should be distributed with the package. 
If not, it can be found here: L<http://www.opensource.org/licenses/mit-license.php>

=cut 
	
__PACKAGE__->meta->make_immutable;

1;
