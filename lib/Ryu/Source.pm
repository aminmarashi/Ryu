package Ryu::Source;

use strict;
use warnings;

use parent qw(Ryu::Node);

# VERSION

=head1 NAME

Ryu::Source - base representation for a source of events

=head1 SYNOPSIS

 my $src = Ryu::Source->new;
 my $chained = $src->map(sub { $_ * $_ })->prefix('value: ')->say;
 $src->emit($_) for 1..5;
 $src->finish;

=head1 DESCRIPTION

This is probably the module you'd want to start with, if you were going to be
using any of this. There's a disclaimer in L<Ryu> that may be relevant at this
point.

=cut

no indirect;

use Future;
use curry::weak;

use Log::Any qw($log);

# Implementation note: it's likely that many new methods will be added to this
# class over time. Most methods have an attempt at "scope-local imports" using
# namespace::clean functionality, this is partly to make it easier to copy/paste
# the code elsewhere for testing, and partly to avoid namespace pollution.

=head1 GLOBALS

=head2 $FUTURE_FACTORY

This is a coderef which should return a new L<Future>-compatible instance.

Example overrides might include:

 $Ryu::Source::FUTURE_FACTORY = sub { Mojo::Future->new->set_label($_[1]) };

=cut

our $FUTURE_FACTORY = sub {
    Future->new->set_label($_[1])
};

# It'd be nice if L<Future> already provided a method for this, maybe I should suggest it
my $future_state = sub {
      $_[0]->is_done
    ? 'done'
    : $_[0]->is_failed
    ? 'failed'
    : $_[0]->is_cancelled
    ? 'cancelled'
    : 'pending'
};

our %ENCODER = (
    utf8 => sub {
        use Encode qw(encode_utf8);
        use namespace::clean qw(encode_utf8);
        sub {
            encode_utf8($_)
        }
    },
    json => sub {
        require JSON::MaybeXS;
        my $json = JSON::MaybeXS->new(@_);
        sub {
            $json->encode($_)
        }
    },
    base64 => sub {
        require MIME::Base64;
        sub {
            MIME::Base64::encode_base64($_, '');
        }
    },
);
$ENCODER{'UTF-8'} = $ENCODER{utf8};

our %DECODER = (
    utf8 => sub {
        use Encode qw(decode_utf8 FB_QUIET);
        use namespace::clean qw(decode_utf8 FB_QUIET);
        my $data = '';
        sub {
            $data .= $_;
            decode_utf8($data, FB_QUIET)
        }
    },
    json => sub {
        require JSON::MaybeXS;
        my $json = JSON::MaybeXS->new(@_);
        sub {
            $json->decode($_)
        }
    },
    base64 => sub {
        require MIME::Base64;
        sub {
            MIME::Base64::decode_base64($_);
        }
    },
);
$DECODER{'UTF-8'} = $DECODER{utf8};

=head1 METHODS

=head2 new

Takes named parameters.

=cut

sub new {
    my ($self, %args) = @_;
    $args{label} //= 'unknown';
    $self->SUPER::new(%args);
}

=head2 describe

Returns a string describing this source and any parents - typically this will result in a chain
like C<< from->combine_latest->count >>.

=cut

sub describe {
    my ($self) = @_;
    ($self->parent ? $self->parent->describe . '=>' : '') . $self->label . '(' . $future_state->($self->completed) . ')';
}

=head2 from

Creates a new source from things.

The precise details of what this method supports may be somewhat ill-defined at this point in time.
It is expected that the interface and internals of this method will vary greatly in versions to come.

=cut

sub from {
    my $class = shift;
    my $src = (ref $class) ? $class : $class->new;
    if(my $from_class = blessed($_[0])) {
        if($from_class->isa('Future')) {
            retain_future(
                $_[0]->on_ready(sub {
                    my ($f) = @_;
                    if($f->failure) {
                        $src->fail($f->from_future);
                    } elsif(!$f->is_cancelled) {
                        $src->finish;
                    } else {
                        $src->emit($f->get);
                        $src->finish;
                    }
                })
            );
            return $src;
        } else {
            die 'Unknown class ' . $from_class . ', cannot turn it into a source';
        }
    } elsif(my $ref = ref($_[0])) {
        if($ref eq 'ARRAY') {
            $src->{on_get} = sub {
                $src->emit($_) for @{$_[0]};
                $src->finish;
            };
            return $src;
        } elsif($ref eq 'GLOB') {
            if(my $fh = *{$_[0]}{IO}) {
                my $code = sub {
                    while(read $fh, my $buf, 4096) {
                        $src->emit($buf)
                    }
                    $src->finish
                };
                $src->{on_get} = $code;
                return $src;
            } else {
                die "have a GLOB with no IO entry, this is not supported"
            }
        }
        die "unsupported ref type $ref";
    } else {
        die "unknown item in ->from";
    }
}

=head2 encode

Passes each item through an encoder.

The first parameter is the encoder to use, the remainder are
used as options for the selected encoder.

Examples:

 $src->encode('json')
 $src->encode('utf8')
 $src->encode('base64')

=cut

sub encode {
    my ($self, $type) = splice @_, 0, 2;
    my $src = $self->chained(label => (caller 0)[3] =~ /::([^:]+)$/);
    my $code = ($ENCODER{$type} || $self->can('encode_' . $type) or die "unsupported encoding $type")->(@_);
    $self->each_while_source(sub {
        $src->emit($code->($_))
    }, $src);
}

=head2 decode

Passes each item through a decoder.

The first parameter is the decoder to use, the remainder are
used as options for the selected decoder.

Examples:

 $src->decode('json')
 $src->decode('utf8')
 $src->decode('base64')

=cut

sub decode {
    my ($self, $type) = splice @_, 0, 2;
    my $src = $self->chained(label => (caller 0)[3] =~ /::([^:]+)$/);
    my $code = ($DECODER{$type} || $self->can('decode_' . $type) or die "unsupported encoding $type")->(@_);
    $self->each_while_source(sub {
        $src->emit($code->($_))
    }, $src);
}

=head2 say

Shortcut for C< ->each(sub { print "\n" }) >.

=cut

sub say {
    my ($self) = @_;
    $self->each(sub { print "$_\n" });
}

=head2 print

Shortcut for C< ->each(sub { print }) >, except this will
also save the initial state of C< $\ > and use that for each
call for consistency.

=cut

sub print {
    my ($self) = @_;
    my $delim = $\;
    $self->each(sub { local $\ = $delim; print });
}

=head2 empty

Creates an empty source, which finishes immediately.

=cut

sub empty {
    my ($self, $code) = @_;

    my $src = $self->chained(label => (caller 0)[3] =~ /::([^:]+)$/);
    $src->finish;
}

=head2 never

An empty source that never finishes.

=cut

sub never {
    my ($self, $code) = @_;

    my $src = $self->chained(label => (caller 0)[3] =~ /::([^:]+)$/);
}

=head2 throw

Throws something. I don't know what, maybe a chair.

=cut

sub throw {
    my $src = shift->new(@_);
    $src->fail('...');
}

=head1 METHODS - Instance

=cut

=head2 new_future

Used internally to get a L<Future>.

=cut

sub new_future {
    my $self = shift;
    (
        $self->{new_future} //= $FUTURE_FACTORY
    )->($self, @_)
}

=head2 pause

Does nothing useful.

=cut

sub pause {
    my $self = shift;
    $self->{is_paused} = 1;
    $self
}

=head2 resume

Is about as much use as L</pause>.

=cut

sub resume {
    my $self = shift;
    $self->{is_paused} = 0;
    $self
}

=head2 is_paused

Might return 1 or 0, but is generally meaningless.

=cut

sub is_paused { $_[0]->{is_paused} }

=head2 debounce

Not yet implemented.

Requires timing support, see implementations such as L<Ryu::Async> instead.

=cut

sub debounce {
    my ($self, $interval) = @_;
    ...
}

=head2 chomp

Chomps all items with the current delimiter.

Once you've instantiated this, it will stick with the delimiter which was in force at the time of instantiation.
Said delimiter follows the usual rules of C<< $/ >>, whatever they happen to be.

=cut

sub chomp {
    my ($self, $delim) = @_;
    $delim //= $/;
    $self->map(sub {
        local $/ = $delim;
        chomp(my $line = $_);
        $line
    })
}

=head2 map

A bit like L<perlfunc/map>.

=cut

sub map : method {
    my ($self, $code) = @_;

    my $src = $self->chained(label => (caller 0)[3] =~ /::([^:]+)$/);
    $self->completed->on_ready(sub {
        return if $src->is_ready;
        shift->on_ready($src->completed);
    });
    $self->each_while_source(sub { $src->emit($_->$code) }, $src);
}

=head2 split

Splits the input into chunks. By default, will split into characters.

=cut

sub split : method {
    my ($self, $delim) = @_;
    $delim //= qr//;

    my $src = $self->chained(label => (caller 0)[3] =~ /::([^:]+)$/);
    $self->completed->on_ready(sub {
        return if $src->is_ready;
        shift->on_ready($src->completed);
    });
    $self->each_while_source(sub { $src->emit($_) for split $delim, $_ }, $src);
}

=head2 chunksize

Splits input into fixed-size chunks.

Note that output is always guaranteed to be a full chunk - if there is partial input
at the time the input stream finishes, those extra bytes will be discarded.

=cut

sub chunksize : method {
    my ($self, $size) = @_;
    die 'need positive chunk size parameter' unless $size && $size > 0;

    my $buffer = '';
    my $src = $self->chained(label => (caller 0)[3] =~ /::([^:]+)$/);
    $self->completed->on_ready(sub {
        return if $src->is_ready;
        shift->on_ready($src->completed);
    });
    $self->each_while_source(sub {
        $buffer .= $_;
        $src->emit(substr $buffer, 0, $size, '') while length($buffer) >= $size;
    }, $src);
}

sub by_line : method {
    my ($self, $delim) = @_;
    $delim //= $/;

    my $src = $self->chained(label => (caller 0)[3] =~ /::([^:]+)$/);
    my $buffer = '';
    $self->completed->on_ready(sub {
        return if $src->is_ready;
        shift->on_ready($src->completed);
    });
    $self->each_while_source(sub {
        $buffer .= $_;
        while($buffer =~ s/^(.*)\Q$delim//) {
            $src->emit($1)
        }
    }, $src);
}

sub prefix {
    my ($self, $txt) = @_;
    my $src = $self->chained(label => (caller 0)[3] =~ /::([^:]+)$/);
    $self->completed->on_ready(sub {
        shift->on_ready($src->completed) unless $src->completed->is_ready
    });
    $self->each_while_source(sub {
        $src->emit($txt . $_)
    }, $src);
}

sub suffix {
    my ($self, $txt) = @_;
    my $src = $self->chained(label => (caller 0)[3] =~ /::([^:]+)$/);
    $self->completed->on_ready(sub {
        shift->on_ready($src->completed) unless $src->completed->is_ready
    });
    $self->each_while_source(sub {
        $src->emit($_ . $txt)
    }, $src);
}

sub sprintf_methods {
    my ($self, $fmt, @methods) = @_;
    my $src = $self->chained(label => (caller 0)[3] =~ /::([^:]+)$/);
    $self->completed->on_ready(sub {
        shift->on_ready($src->completed) unless $src->completed->is_ready
    });
    $self->each_while_source(sub {
        my ($item) = @_;
        $src->emit(sprintf $fmt, map $item->$_, @methods)
    }, $src);
}

=head2 as_list

Resolves to a list consisting of all items emitted by this source.

=cut

sub as_list {
    my ($self) = @_;
    my @data;
    $self->each(sub {
        push @data, $_
    });
    $self->completed->transform(done => sub { @data })
}

=head2 as_arrayref

Resolves to a single arrayref consisting of all items emitted by this source.

=cut

sub as_arrayref {
    my ($self) = @_;
    my @data;
    $self->each(sub {
        push @data, $_
    });
    $self->completed->transform(done => sub { \@data })
}

=head2 as_string

Concatenates all items into a single string.

Returns a L<Future> which will resolve on completion.

=cut

sub as_string {
    my ($self) = @_;
    my $data = '';
    $self->each(sub {
        $data .= $_;
    });
    $self->completed->transform(done => sub { $data })
}

=head2 combine_latest

=cut

sub combine_latest : method {
    use Scalar::Util qw(blessed);
    use Variable::Disposition qw(retain_future);
    use namespace::clean qw(blessed retain_future);
    my ($self, @sources) = @_;
    push @sources, sub { @_ } if blessed $sources[-1];
    my $code = pop @sources;

    my $combined = $self->chained(label => (caller 0)[3] =~ /::([^:]+)$/);
    unshift @sources, $self if ref $self;
    my @value;
    my %seen;
    for my $idx (0..$#sources) {
        my $src = $sources[$idx];
        $src->each_while_source(sub {
            $value[$idx] = $_;
            $seen{$idx} ||= 1;
            $combined->emit([ $code->(@value) ]) if @sources == keys %seen;
        }, $combined);
    }
    retain_future(
        Future->needs_any(
            map $_->completed, @sources
        )->on_ready(sub {
            @value = ();
            return if $combined->completed->is_ready;
            shift->on_ready($combined->completed)
        })
    );
    $combined
}

=head2 with_index

Emits arrayrefs consisting of C<< [ $item, $idx ] >>.

=cut

sub with_index {
    my ($self) = @_;
    my $src = $self->chained(label => (caller 0)[3] =~ /::([^:]+)$/);
    my $idx = 0;
    $self->each_while_source(sub {
        $src->emit([ $_, $idx++ ])
    }, $src);
}

=head2 with_latest_from

=cut

sub with_latest_from : method {
    use Scalar::Util qw(blessed);
    use namespace::clean qw(blessed);
    my ($self, @sources) = @_;
    push @sources, sub { @_ } if blessed $sources[-1];
    my $code = pop @sources;

    my $combined = $self->chained(label => (caller 0)[3] =~ /::([^:]+)$/);
    my @value;
    my %seen;
    for my $idx (0..$#sources) {
        my $src = $sources[$idx];
        $src->each(sub {
            return if $combined->completed->is_ready;
            $value[$idx] = $_;
            $seen{$idx} ||= 1;
        });
    }
    $self->each(sub {
        $combined->emit([ $code->(@value) ]) if keys %seen;
    });
    $self->completed->on_ready($combined->completed);
    $self->completed->on_ready(sub {
        @value = ();
        return if $combined->is_ready;
        shift->on_ready($combined->completed);
    });
    $combined
}

=head2 merge

=cut

sub merge : method {
    use Variable::Disposition qw(retain_future);
    use namespace::clean qw(retain_future);
    my ($self, @sources) = @_;

    my $combined = $self->chained(label => (caller 0)[3] =~ /::([^:]+)$/);
    unshift @sources, $self if ref $self;
    for my $src (@sources) {
        $src->each(sub {
            return if $combined->completed->is_ready;
            $combined->emit($_)
        });
    }
    retain_future(
        Future->needs_all(
            map $_->completed, @sources
        )->on_ready($combined->completed)
    );
    $combined
}

=head2 apply

Used for setting up multiple streams.

Accepts a variable number of coderefs, will call each one and gather L<Ryu::Source>
results.

=cut

sub apply : method {
    use Variable::Disposition qw(retain_future);
    use namespace::clean qw(retain_future);
    my ($self, @code) = @_;

    my $src = $self->chained(label => (caller 0)[3] =~ /::([^:]+)$/);
    my @pending;
    for my $code (@code) {
        push @pending, map $code->($_), $self;
    }
    retain_future(
        Future->needs_all(
            map $_->completed, @pending
        )->on_ready($src->completed)
    );
    # Pass through the original events
    $self->each_while_source(sub {
        $src->emit($_)
    }, $src)
}

=head2 each_as_source

=cut

sub each_as_source : method {
    use Variable::Disposition qw(retain_future);
    use namespace::clean qw(retain_future);
    my ($self, @code) = @_;

    my $src = $self->chained(label => (caller 0)[3] =~ /::([^:]+)$/);
    my @active;
    $self->completed->on_ready(sub {
        retain_future(
            Future->needs_all(
                grep $_, @active
            )->on_ready(sub {
                $src->finish
            })
        );
    });

    $self->each_while_source(sub {
        my @pending;
        for my $code (@code) {
            push @pending, $code->($_);
        }
        push @active, map $_->completed, @pending;
        $src->emit($_);
    }, $src)
}

=head2 switch_str

Given a condition, will select one of the alternatives based on stringified result.

Example:

 $src->switch_str(
  sub { $_->name }, # our condition
  smith => sub { $_->id }, # if this matches the condition, the code will be called with $_ set to the current item
  jones => sub { $_->parent->id },
  sub { undef } # and this is our default case
 );

=cut

sub switch_str {
    use Variable::Disposition qw(retain_future);
    use Scalar::Util qw(blessed);
    use namespace::clean qw(retain_future);
    my ($self, $condition, @args) = @_;

    my $src = $self->chained(label => (caller 0)[3] =~ /::([^:]+)$/);
    my @active;
    $self->completed->on_ready(sub {
        retain_future(
            Future->needs_all(
                grep $_, @active
            )->on_ready(sub {
                $src->finish
            })
        );
    });

    $self->each_while_source(sub {
        my ($item) = $_;
        my $rslt = $condition->($item);
        retain_future(
            (blessed($rslt) && $rslt->isa('Future') ? $rslt : Future->done($rslt))->on_done(sub {
                my ($data) = @_;
                my @copy = @args;
                while(my ($k, $v) = splice @copy, 0, 2) {
                    if(!defined $v) {
                        # Only a single value (or undef)? That's our default, just use it as-is
                        return $src->emit(map $k->($_), $item)
                    } elsif($k eq $data) {
                        # Key matches our result? Call code with the original item
                        return $src->emit(map $v->($_), $item)
                    }
                }
            })
        )
    }, $src)
}

=head2 ordered_futures

Given a stream of L<Future>s, will emit the results as each L<Future>
is marked ready. If any fail, the stream will fail.

This is a terrible name for a method, expect it to change.

=cut

sub ordered_futures {
    use Variable::Disposition qw(retain_future);
    use namespace::clean qw(retain_future);
    my ($self) = @_;
    my $src = $self->chained(label => (caller 0)[3] =~ /::([^:]+)$/);
    $self->each_while_source(sub {
        retain_future(
            $_->on_done($src->curry::weak::emit)
              ->on_fail($src->curry::weak::fail)
        )
    }, $src);
}

=head2 distinct

Emits new distinct items, using string equality with an exception for
C<undef> (i.e. C<undef> is treated differently from empty string or 0).

Given 1,2,3,undef,2,3,undef,'2',2,4,1,5, you'd expect to get the sequence 1,2,3,undef,4,5.

=cut

sub distinct {
    my $self = shift;

    my $src = $self->chained(label => (caller 0)[3] =~ /::([^:]+)$/);
    my %seen;
    my $undef;
    $self->each_while_source(sub {
        if(defined) {
            $src->emit($_) unless $seen{$_}++;
        } else {
            $src->emit($_) unless $undef++;
        }
    }, $src);
}

=head2 distinct_until_changed

Removes contiguous duplicates, defined by string equality.

=cut

sub distinct_until_changed {
    my $self = shift;

    my $src = $self->chained(label => (caller 0)[3] =~ /::([^:]+)$/);
    my $active;
    my $prev;
    $self->each_while_source(sub {
        if($active) {
            if(defined($prev) ^ defined($_)) {
                $src->emit($_)
            } elsif(defined($_)) {
                $src->emit($_) if $prev ne $_;
            }
        } else {
            $active = 1;
            $src->emit($_);
        }
        $prev = $_;
    }, $src);
    $src
}

=head2 sort_by

Emits items sorted by the given key. This is a stable sort function.

The algorithm is taken from L<List::UtilsBy>.

=cut

sub sort_by {
    use sort qw(stable);
    my ($self, $code) = @_;
    my $src = $self->chained(label => (caller 0)[3] =~ /::([^:]+)$/);
    my @items;
    my @keys;
    $self->completed->on_done(sub {
        $src->emit($_) for @items[sort { $keys[$a] cmp $keys[$b] } 0 .. $#items];
    })->on_ready(sub {
        return if $src->is_ready;
        shift->on_ready($src->completed);
    });
    $self->each_while_source(sub {
        push @items, $_;
        push @keys, $_->$code;
    }, $src);
}

=head2 nsort_by

Emits items numerically sorted by the given key. This is a stable sort function.

See L</sort_by>.

=cut

sub nsort_by {
    use sort qw(stable);
    my ($self, $code) = @_;
    my $src = $self->chained(label => (caller 0)[3] =~ /::([^:]+)$/);
    my @items;
    my @keys;
    $self->completed->on_done(sub {
        $src->emit($_) for @items[sort { $keys[$a] <=> $keys[$b] } 0 .. $#items];
    })->on_ready(sub {
        return if $src->is_ready;
        shift->on_ready($src->completed);
    });
    $self->each_while_source(sub {
        push @items, $_;
        push @keys, $_->$code;
    }, $src);
}

=head2 rev_sort_by

Emits items sorted by the given key. This is a stable sort function.

The algorithm is taken from L<List::UtilsBy>.

=cut

sub rev_sort_by {
    use sort qw(stable);
    my ($self, $code) = @_;
    my $src = $self->chained(label => (caller 0)[3] =~ /::([^:]+)$/);
    my @items;
    my @keys;
    $self->completed->on_done(sub {
        $src->emit($_) for @items[sort { $keys[$b] cmp $keys[$a] } 0 .. $#items];
    })->on_ready(sub {
        return if $src->is_ready;
        shift->on_ready($src->completed);
    });
    $self->each_while_source(sub {
        push @items, $_;
        push @keys, $_->$code;
    }, $src);
}

=head2 rev_nsort_by

Emits items numerically sorted by the given key. This is a stable sort function.

See L</sort_by>.

=cut

sub rev_nsort_by {
    use sort qw(stable);
    my ($self, $code) = @_;
    my $src = $self->chained(label => (caller 0)[3] =~ /::([^:]+)$/);
    my @items;
    my @keys;
    $self->completed->on_done(sub {
        $src->emit($_) for @items[sort { $keys[$b] <=> $keys[$a] } 0 .. $#items];
    })->on_ready(sub {
        return if $src->is_ready;
        shift->on_ready($src->completed);
    });
    $self->each_while_source(sub {
        push @items, $_;
        push @keys, $_->$code;
    }, $src);
}

=head2 extract_all

Expects a regular expression and emits hashrefs containing
the named capture buffers.

The regular expression will be applied using the m//gc operator.

Example:

 $src->extract_all(qr{/(?<component>[^/]+)})
 # emits { component => '...' }, { component => '...' }

=cut

sub extract_all {
    my ($self, $pattern) = @_;
    my $src = $self->chained(label => (caller 0)[3] =~ /::([^:]+)$/);
    $self->completed->on_ready(sub {
        return if $src->is_ready;
        shift->on_ready($src->completed);
    });
    $self->each_while_source(sub {
        $src->emit(+{ %+ }) while m/$pattern/gc;
    }, $src);
}

=head2 skip

Skips the first N items.

=cut

sub skip {
    my ($self, $count) = @_;
    $count //= 0;

    my $src = $self->chained(label => (caller 0)[3] =~ /::([^:]+)$/);
    $self->completed->on_ready(sub {
        return if $src->is_ready;
        shift->on_ready($src->completed);
    });
    $self->each(sub {
        $src->emit($_) unless $count-- > 0;
    });
    $src
}

=head2 skip_last

Skips the last N items.

=cut

sub skip_last {
    my ($self, $count) = @_;
    $count //= 0;

    my $src = $self->chained(label => (caller 0)[3] =~ /::([^:]+)$/);
    $self->completed->on_ready(sub {
        return if $src->is_ready;
        shift->on_ready($src->completed);
    });
    my @pending;
    $self->each(sub {
        push @pending, $_;
        $src->emit(shift @pending) if @pending > $count;
    });
    $src
}

=head2 take

Takes a limited number of items.

Given a sequence of C< 1,2,3,4,5 > and C<< ->take(3) >>, you'd get 1,2,3 and then the stream
would finish.

=cut

sub take {
    my ($self, $count) = @_;
    $count //= 0;
    return $self->empty unless $count > 0;

    my $src = $self->chained(label => (caller 0)[3] =~ /::([^:]+)$/);
    $self->completed->on_ready(sub {
        return if $src->is_ready;
        shift->on_ready($src->completed);
    });
    # $self->completed->on_ready($src->completed);
    $self->each_while_source(sub {
        $log->tracef("Still alive with %d remaining", $count);
        $src->emit($_);
        return if --$count;
        $log->tracef("Count is zero, finishing");
        $src->finish
    }, $src);
}

=head2 some

=cut

sub some {
    my ($self, $code) = @_;

    my $src = $self->chained(label => (caller 0)[3] =~ /::([^:]+)$/);
    $self->completed->on_ready(sub {
        my $sf = $src->completed;
        return if $sf->is_ready;
        my $f = shift;
        return $f->on_ready($sf) unless $f->is_done;
        $src->emit(0);
        $sf->done;
    });
    $self->each(sub {
        return if $src->completed->is_ready;
        return unless $code->($_);
        $src->emit(1);
        $src->completed->done 
    });
    $src
}

=head2 every

=cut

sub every {
    my ($self, $code) = @_;

    my $src = $self->chained(label => (caller 0)[3] =~ /::([^:]+)$/);
    $self->completed->on_done(sub {
        return if $src->completed->is_ready;
        $src->emit(1);
        $src->completed->done 
    });
    $self->each(sub {
        return if $src->completed->is_ready;
        return if $code->($_);
        $src->emit(0);
        $src->completed->done 
    });
    $src
}

=head2 count

=cut

sub count {
    my ($self) = @_;

    my $count = 0;

    my $src = $self->chained(label => (caller 0)[3] =~ /::([^:]+)$/);
    $self->completed->on_done(sub {
        $src->emit($count)
    })->on_ready(
        $src->completed
    );
    $self->each_while_source(sub { ++$count }, $src);
}

=head2 sum

=cut

sub sum {
    my ($self) = @_;

    my $sum = 0;

    my $src = $self->chained(label => (caller 0)[3] =~ /::([^:]+)$/);
    $self->completed->on_done(sub {
        $src->emit($sum)
    })->on_ready(
        $src->completed
    );
    $self->each_while_source(sub {
        $sum += $_
    }, $src);
}

=head2 mean

=cut

sub mean {
    my ($self) = @_;

    my $sum = 0;
    my $count = 0;

    my $src = $self->chained(label => (caller 0)[3] =~ /::([^:]+)$/);
    $self->each(sub { ++$count; $sum += $_ });
    $self->completed->on_done(sub { $src->emit($sum / ($count || 1)) })
        ->on_ready($src->completed);
    $src
}

=head2 max

=cut

sub max {
    my ($self) = @_;

    my $src = $self->chained(label => (caller 0)[3] =~ /::([^:]+)$/);
    my $max;
    $self->each(sub {
        return if defined $max and $max > $_;
        $max = $_;
    });
    $self->completed->on_done(sub { $src->emit($max) })
        ->on_ready($src->completed);
    $src
}

=head2 min

=cut

sub min {
    my ($self) = @_;

    my $src = $self->chained(label => (caller 0)[3] =~ /::([^:]+)$/);
    my $min;
    $self->each(sub {
        return if defined $min and $min < $_;
        $min = $_;
    });
    $self->completed->on_done(sub { $src->emit($min) })
        ->on_ready($src->completed);
    $src
}

=head2 statistics

Emits a single hashref of statistics once the source completes.

=cut

sub statistics {
    my ($self) = @_;

    my $sum = 0;
    my $count = 0;
    my $min;
    my $max;

    my $src = $self->chained(label => (caller 0)[3] =~ /::([^:]+)$/);
    $self->each(sub {
        $min //= $_;
        $max //= $_;
        $min = $_ if $_ < $min;
        $max = $_ if $_ > $max;
        ++$count;
        $sum += $_
    });
    $self->completed->on_done(sub {
        $src->emit({
            count => $count,
            sum   => $sum,
            min   => $min,
            max   => $max,
            mean  => ($sum / ($count || 1))
        })
    })
        ->on_ready($src->completed);
    $src
}

=head2 filter

=cut

sub filter {
    use Scalar::Util qw(blessed);
    use namespace::clean qw(blessed);
    my $self = shift;

    my $src = $self->chained(label => (caller 0)[3] =~ /::([^:]+)$/);
    $self->completed->on_ready(sub {
        return if $src->is_ready;
        shift->on_ready($src->completed);
    });
    $self->each_while_source((@_ > 1) ? do {
        my %args = @_;
        my $check = sub {
            my ($k, $v) = @_;
            if(my $ref = ref $args{$k}) {
                if($ref eq 'Regexp') {
                    return 0 unless $v =~ $args{$k};
                } elsif($ref eq 'CODE') {
                    return 0 for grep !$args{$k}->($_), $v;
                } else {
                    die "Unsure what to do with $args{$k} which seems to be a $ref";
                }
            } else {
                return 0 unless $v eq $args{$k};
            }
            return 1;
        };
        sub {
            my $item = shift;
            if(blessed $item) {
                for my $k (keys %args) {
                    my $v = $item->$k;
                    return unless $check->($k, $v);
                }
            } elsif(my $ref = ref $item) {
                if($ref eq 'HASH') {
                    for my $k (keys %args) {
                        my $v = $item->{$k};
                        return unless $check->($k, $v);
                    }
                } else {
                    die 'not a ref we know how to handle: ' . $ref;
                }
            } else {
                die 'not a ref, not sure what to do now';
            }
            $src->emit($item);
        }
    } : do {
        my $code = shift;
        if(my $ref = ref($code)) {
            if($ref eq 'Regexp') {
                my $re = $code;
                $code = sub { /$re/ };
            } elsif($ref eq 'CODE') {
                # use as-is
            } else {
                die "not sure how to handle $ref";
            }
        }
        sub {
            my $item = shift;
            $src->emit($item) if $code->($item);
        }
    }, $src);
}

=head2 emit

=cut

sub emit {
    use Syntax::Keyword::Try;
    use namespace::clean qw(try catch finally);
    my $self = shift;
    my $completion = $self->completed;
    for (@_) {
        for my $code (@{$self->{on_item}}) {
            die 'already completed' if $completion->is_ready;
            try {
                $code->($_);
            } catch {
                my $ex = $@;
                $log->warnf("Exception raised in %s - %s", (eval { $self->describe } // "<failed>"), "$ex");
                $completion->fail($ex, source => 'exception in on_item callback');
                die $ex;
            }
        }
    }
    $self
}

=head2 flat_map

Similar to L</map>, but will flatten out some items:

=over 4

=item * an arrayref will be expanded out to emit the individual elements

=item * for a L<Ryu::Source>, passes on any emitted elements

=back

This also means you can "merge" items from a series of sources.

Note that this is not recursive - an arrayref of arrayrefs will be expanded out
into the child arrayrefs, but no further.

=cut

sub flat_map {
    use Scalar::Util qw(blessed weaken);
    use Ref::Util qw(is_plain_arrayref is_plain_coderef);
    use namespace::clean qw(blessed is_plain_arrayref is_plain_coderef weaken);

    my ($self, $code) = splice @_, 0, 2;

    # Upgrade ->flat_map(method => args...) to a coderef
    if(!is_plain_coderef($code)) {
        my $method = $code;
        my @args = @_;
        $code = sub { $_->$method(@args) }
    }

    my $src = $self->chained(label => (caller 0)[3] =~ /::([^:]+)$/);

    weaken(my $weak_sauce = $src);
    my $add = sub  {
        my $v = shift;
        my $src = $weak_sauce or return;

        my $k = "$v";
        $log->tracef("Adding %s which will bring our count to %d", $k, 0 + keys %{$src->{waiting}});
        $src->{waiting}{$k} = $v->on_ready(sub {
            return unless my $src = $weak_sauce;
            delete $src->{waiting}{$k};
            $src->finish unless %{$src->{waiting}};
        })
    };

    $add->($self->completed);
    $self->each_while_source(sub {
        my $src = $weak_sauce or return;
        for ($code->($_)) {
            my $item = $_;
            if(is_plain_arrayref($item)) {
                $log->tracef("Have an arrayref of %d items", 0 + @$item);
                for(@$item) {
                    last if $src->is_ready;
                    $src->emit($_);
                }
            } elsif(blessed($item) && $item->isa(__PACKAGE__)) {
                $log->tracef("This item is a source");
                $add->($item->completed);
                $src->on_ready(sub {
                    return if $item->is_ready;
                    $log->tracef("Marking %s as ready because %s was", $item->describe, $src->describe);
                    shift->on_ready($item->completed);
                });
                $item->each_while_source(sub {
                    my $src = $weak_sauce or return;
                    $src->emit($_)
                }, $src)->on_ready(sub {
                    undef $item;
                });
            }
        }
    }, $src);
    $src
}

=head2 each

=cut

sub each {
    my ($self, $code, %args) = @_;
    push @{$self->{on_item}}, $code;
    $self;
}

=head2 completed

=cut

sub completed {
    my ($self) = @_;
    $self->{completed} //= $self->new_future(
        'completion'
    )->on_ready(
        $self->curry::weak::cleanup
    )
}

sub cleanup {
    my ($self) = @_;
    $log->tracef("Cleanup for %s (f = %s)", $self->describe, 0 + $self->completed);
    $self->parent->notify_child_completion($self) if $self->parent;
    delete @{$self}{qw(on_item)};
    $log->tracef("Finished cleanup for %s", $self->describe);
}

sub notify_child_completion {
    use Scalar::Util qw(refaddr);
    use List::UtilsBy qw(extract_by);
    use namespace::clean qw(refaddr extract_by);

    my ($self, $child) = @_;
    if(extract_by { refaddr($child) == refaddr($_) } @{$self->{children}}) {
        $log->tracef(
            "Removed completed child %s, have %d left",
            $child->describe,
            0 + @{$self->{children}}
        );
        return $self if $self->is_ready;
        return $self if @{$self->{children}};

        $log->tracef(
            "This was the last child, cancelling %s",
            $self->describe
        );
        $self->cancel;
        return $self;
    }

    $log->warnf("Child %s (addr 0x%x) not found in list for %s", $child->describe, $self->describe);
    $log->tracef("* %s (addr 0x%x)", $_->describe, refaddr($_)) for @{$self->{children}};
    $self
}

sub label { shift->{label} }

sub parent { shift->{parent} }

=head1 METHODS - Proxied

The following methods are proxied to our completion L<Future>:

=over 4

=item * then

=item * is_ready

=item * is_done

=item * failure

=item * is_cancelled

=item * else

=back

=cut

sub get {
    my ($self) = @_;
    my $f = $self->completed;
    my @rslt;
    $self->each(sub { push @rslt, $_ }) if defined wantarray;
    if(my $parent = $self->parent) {
        $parent->await
    }
    (delete $self->{on_get})->() if $self->{on_get};
    $f->transform(done => sub {
        @rslt
    })->get
}

for my $k (qw(then cancel fail on_ready transform is_ready is_done failure is_cancelled else)) {
    do { no strict 'refs'; *$k = $_ } for sub { shift->completed->$k(@_) }
}

=head2 await

Block until this source finishes.

=cut

sub await {
    my ($self) = @_;
    my $f = $self->completed;
    $f->await until $f->is_ready;
    $self
}

=head2 finish

Mark this source as completed.

=cut

sub finish { shift->completed->done }

sub refresh { }

=head1 METHODS - Internal

=head2 chained

Returns a new L<Ryu::Source> chained from this one.

=cut

sub chained {
    use Scalar::Util qw(weaken);
    use namespace::clean qw(weaken);

    my ($self) = shift;
    if(my $class = ref($self)) {
        my $src = $class->new(
            new_future => $self->{new_future},
            parent     => $self,
            @_
        );
        weaken($src->{parent});
        push @{$self->{children}}, $src;
        $log->tracef("Constructing chained source for %s from %s (%s)", $src->label, $self->label, $future_state->($self->completed));
        return $src;
    } else {
        my $src = $self->new(@_);
        $log->tracef("Constructing chained source for %s with no parent", $src->label, $self->label);
    }
}

=head2 each_while_source

Like L</each>, but removes the source from the callback list once the
parent completes.

=cut

sub each_while_source {
    use Scalar::Util qw(refaddr);
    use List::UtilsBy qw(extract_by);
    use namespace::clean qw(refaddr extract_by);
    my ($self, $code, $src) = @_;
    $self->each($code);
    $src->completed->on_ready(sub {
        my $count = extract_by { refaddr($_) == refaddr($code) } @{$self->{on_item}};
        $log->tracef("->e_w_s completed on %s for refaddr 0x%x", $self->describe, refaddr($self));
    });
    $src
}

sub DESTROY {
    my ($self) = @_;
    return if ${^GLOBAL_PHASE} eq 'DESTRUCT';
    $log->tracef("Destruction for %s", $self->describe);
    $self->completed->cancel unless $self->completed->is_ready;
}

sub catch {
    use Scalar::Util qw(blessed);
    use namespace::clean qw(blessed);
    my ($self, $code) = @_;
    my $src = $self->chained(label => (caller 0)[3] =~ /::([^:]+)$/);
    $self->completed->on_fail(sub {
        my @failure = @_;
        my $sub = $code->(@failure);
        if(blessed $sub && $sub->isa('Ryu::Source')) {
            $sub->each_while_source(sub {
                $src->emit($_)
            }, $src);
        } else {
            $sub->fail(@failure);
        }
    });
    $self->each_while_source(sub {
        $src->emit($_)
    }, $src);
}

1;

__END__

=head1 AUTHOR

Tom Molesworth <TEAM@cpan.org>

=head1 LICENSE

Copyright Tom Molesworth 2011-2017. Licensed under the same terms as Perl itself.

