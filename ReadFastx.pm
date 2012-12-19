{
  package ReadFastx;
  use Mouse;
  use Carp;
  use FileBar;
  
  our $VERSION = '0.10';
  
  has fh => (is => 'ro', isa => 'GlobRef');
  has files => (is => 'ro', default => sub { \@ARGV }, isa => 'ArrayRef[Str]');
  has current_file => (is => 'rw', trigger => \&_current_file, isa => 'Str');
  has alignments_only => (is => 'ro', default => 0, isa => 'Bool');
  
  around BUILDARGS => sub {
    my $orig  = shift;
    my $class = shift;
    if (@_ == 1 && !ref $_[0]) {
      return $class->$orig(files => [$_[0]]);
    }
    else {
      return $class->$orig(@_);
    }
  };
  
  sub BUILD {
    my $self = shift;
    unless ($self->{fh}) {
  
      #automatically unzip gzip and bzip files
      @{$self->{files}} = map {
        s/(.*\.gz)\s*$/pigz -dc < $1|/;
        s/(.*\.bz2)\s*$/pbzip2 -dc < $1|/;
        $_
      } @{$self->{files}};
  
      #if no files read from stdin
      $self->{files} = ['-'] unless @{$self->{files}};
  
    }
    $self->{file_itr} = 0;
    $self->current_file($self->files->[0]);
  }
  
  sub next_file {
    my ($self) = shift;
    $self->{file_itr}++;
    return if $self->{file_itr} >= @{$self->files};
    $self->current_file($self->files->[$self->{file_itr}]);
  }
  
  sub _current_file {
    my ($self, $file) = @_;
    open my $fh, $file or croak "$!: Could not open $file\n";
    $self->{fh} = $fh;
    if (not $self->{bar}) {
      $self->{bar} = FileBar->new(current_file => $self->{current_file}, files => $self->files, fh_in => $self->fh);
    }
    else {
      $self->{bar}->fh_in($fh);
      $self->{bar}->current_file($self->{current_file});
    }
    my $first_char = getc $self->{fh};
    $self->{reader} =
        $first_char eq ">" ? sub { $self->_read_fasta }
      : $first_char eq "@" ? sub { $self->_read_fastq }
      :                      croak "Not a fasta or fastq file, $first_char is not > or @";
  }
  
  sub next_seq {
    my ($self) = shift;
    return &{$self->{reader}};
  }
  
  sub _read_fasta {
    my $self = shift;
    local $/ = ">";
    if (my $record = readline $self->{fh}) {
      chomp $record;
      my $newline = index($record, "\n");
      if ($newline > 1) {
        my $header = substr($record, 0, $newline);
        my $sequence = substr($record, $newline + 1);
        $sequence =~ tr/\n//d;
        return ReadFastx::Fasta->new(header => $header, sequence => $sequence);
      }
    }
    elsif ($self->_end_of_files()) {
      $self->next_file();
      return ($self->_read_fasta);
    }
    else {
      return undef;
    }
  }
  
  sub _read_delim {
    my ($fh, $delim) = @_;
    local $/ = $delim;
    my $data = readline $fh;
    if ($data) {
      chomp $data;
      return $data;
    }
    return;
  }
  
  sub _read_fastq {
    my $self     = shift;
    my $header   = _read_delim($self->{fh}, "\n");
    my $sequence = _read_delim($self->{fh}, "\n+");
    my $h2       = _read_delim($self->{fh}, "\n");
    my $quality  = _read_delim($self->{fh}, "\n@");
    if ($header and $sequence and $quality) {
      $header =~ s/^@//;    #remove @ if it exists
      $sequence =~ tr/\n//d;
      $quality =~ tr/\n//d;
      return ReadFastx::Fastq->new(header => $header, sequence => $sequence, quality => $quality);
    }
    elsif ($self->_end_of_files()) {
      $self->next_file();
      return ($self->_read_fasta);
    }
    else {
      return undef;
    }
  }
  
  sub _end_of_files {
    my $self = shift;
    return (eof $self->{fh} and $self->{file_itr} < @{$self->{files}});
  }
  
  __PACKAGE__->meta->make_immutable;
}

{
  package ReadFastx::Fastx;
  use Mouse;
  use Readonly;
  
  has header   => (is => 'rw', isa => 'Str');
  has sequence => (is => 'rw', isa => 'Str');
  
  sub _wrap {
    my ($self, $string, $width) = @_;
    if ($width) {
      my $out = '';
      my $cur = 0;
      while ($cur < length($string)) {
        $out .= substr($string, $cur, $width) . "\n";
        $cur += $width;
      }
      return $out;
    }
    return $string, "\n";
  }
  __PACKAGE__->meta->make_immutable;
}

{
  package ReadFastx::Fasta;
  use Mouse;
  use Readonly;
  
  Readonly my $PRINT_DEFAULT_FH => \*STDOUT;
  
  extends ReadFastx::Fastx;
  
  sub print {
    my ($self) = shift;
    my $args  = @_ == 1 && ref $_[0]  ? $_[0]          : {@_};
    my $fh    = exists $args->{fh}    ? $args->{fh}    : $PRINT_DEFAULT_FH;
    my $width = exists $args->{width} ? $args->{width} : undef;
    print $fh ">", $self->{header}, "\n", _wrap($self->{sequence}, $width);
  }
  
  __PACKAGE__->meta->make_immutable;
}

{
  package ReadFastx::Fastq;
  use Mouse;
  use Readonly;
  
  extends ReadFastx::Fastx;
  
  Readonly my $PRINT_DEFAULT_FH => \*STDOUT;
  Readonly my $ILLUMINA_OFFSET => 64;
  Readonly my $SANGER_OFFSET   => 32;
  
  has quality => (is         => 'rw',
                  isa        => 'Str',
                  trigger    => sub { $_[0]->clear_quality_array },
                  lazy_build => 1);
  has quality_array => (traits     => ['Array'],
                        writer     => 'quality_array',
                        isa        => 'ArrayRef[Int]',
                        lazy_build => 1,
                        trigger    => sub { $_[0]->clear_quality},
                        handles    => {quality_values => 'elements', quality_at => 'accessor'});
  has is_illumina => (is => 'rw', isa => 'Bool', default => 0);
  
  sub _build_quality {
    my ($self) = shift;
    my $offset = $self->is_illumina ? $ILLUMINA_OFFSET : $SANGER_OFFSET;
    return pack "c*", map { $_ + $offset } @{$self->{quality_array}};
  }
  
  sub _build_quality_array {
    my ($self) = shift;
    my $offset = $self->is_illumina ? $ILLUMINA_OFFSET : $SANGER_OFFSET;
    return [map { $_ - $offset } unpack "c*", $self->quality];
  }
  
  sub print {
    my ($self) = shift;
    my $args   = @_ == 1 && ref $_[0]  ? $_[0]            : {@_};
    my $fh     = exists $args->{fh}    ? $args->{fh}      : $PRINT_DEFAULT_FH;
    my $offset = $self->is_illumina    ? $ILLUMINA_OFFSET : $SANGER_OFFSET;
    my $width  = exists $args->{width} ? $args->{width}   : undef;
    print $fh "@", $self->header, "\n", $self->_wrap($self->sequence, $width), "+", $self->header, "\n", $self->_wrap($self->quality, $width);
  }
  
  __PACKAGE__->meta->make_immutable;
}
use namespace::autoclean;
1;
