package Coastlines;

# ABSTRACT: merge coastlines and generate sea areas

# $Id$


use 5.010;
use strict;
use warnings;

use Carp;
use List::Util qw/ reduce /;
use List::MoreUtils qw/ any /;

use Math::Polygon;
use Math::Polygon::Tree;



=method new

    my $coast = Coastlines->new( \@bound );

Constructor

=cut

sub new {
    my ($class, $boundary) = @_;
    return bless { lines => {}, bound => $boundary }, $class;
}



sub _point_key {
    my ($point) = @_;
    return join q{,}, @$point;
}


=method add_coastline

    $coast->add_coastline( [ [$x1, $y1], ... ], ... );

Add area to tree.

=cut

sub add_coastline {
    my ($self, @lines ) = @_;

    for my $chain ( @lines ) {
        my $key = _point_key($chain->[0]);

        if ( exists $self->{lines}->{$key} ) {
            carp "Coastline at ($key) already exists";
            next;
        }

        $self->{lines}->{$key} = $chain;
    }

    return;
}


=method generate_polygons

    my @polygons = $coast->generate_polygons(%opt);

Options:
    water_background


=cut

sub generate_polygons {
    my ($self, %opt) = @_;
    my ($coast, $bound) = @$self{ 'lines', 'bound' };

    return if !%$coast;

    ##  merging
    my @keys = keys %$coast;
    for my $line_start ( @keys ) {
        my $line = $coast->{$line_start};
        next  if !$line;

        my $line_end = _point_key($line->[-1]);
        next  if $line_end eq $line_start;

        my $merge_line = delete $coast->{$line_end};
        next if !$merge_line;

        pop  @$line;
        push @$line, @$merge_line;
        redo;
    }

    ##  tracing bounds
    my $boundcross = 0;
    if ( @$bound ) {
        my @tbound;
        my $pos = 0;

        for my $i ( 0 .. $#$bound-1 ) {
            push @tbound, {
                type    =>  'bound',
                point   =>  $bound->[$i],
                pos     =>  $pos,
            };

            for my $key ( keys %$coast ) {

                my $line = $coast->{$key};
                
                # check start of coastline
                my $p1     = $line->[0];
                my $p2     = $line->[1]; # [ reverse  split q{,}, $nodes->{$coast{$sline}->[1]} ];
                my $ipoint = _segment_intersection( $bound->[$i], $bound->[$i+1], $p1, $p2 );

                if ( $ipoint ) {
                    if ( any { $_->{type} eq 'end'  &&  $_->{point} ~~ $ipoint } @tbound ) {
                        @tbound = grep { !( $_->{type} eq 'end'  &&  $_->{point} ~~ $ipoint ) } @tbound;
                    }
                    else {
                        $boundcross ++;
                        push @tbound, {
                            type    =>  'start',
                            point   =>  $ipoint,
                            pos     =>  $pos + _segment_length( $bound->[$i], $ipoint ),
                            line    =>  $key,
                        };
                    }
                }

                # check end of coastline
                $p1      = $line->[-1];
                $p2      = $line->[-2];
                $ipoint  = _segment_intersection( $bound->[$i], $bound->[$i+1], $p1, $p2 );

                if ( $ipoint ) {
                    if ( any { $_->{type} eq 'start'  &&  $_->{point} ~~ $ipoint } @tbound ) {
                        @tbound = grep { !( $_->{type} eq 'start'  &&  $_->{point} ~~ $ipoint ) } @tbound;
                    }
                    else {
                        $boundcross ++;
                        push @tbound, {
                            type    =>  'end',
                            point   =>  $ipoint,
                            pos     =>  $pos + _segment_length( $bound->[$i], $ipoint ),
                            line    =>  $key,
                        };
                    }
                }
            }

            $pos += _segment_length( $bound->[$i], $bound->[$i+1] );
        }

        # rotate if sea at $tbound[0]
        my $tmp  =  reduce { $a->{pos} < $b->{pos} ? $a : $b }  grep { $_->{type} ne 'bound' } @tbound;
        if ( $tmp->{type} && $tmp->{type} eq 'end' ) {
            for ( grep { $_->{pos} <= $tmp->{pos} } @tbound ) {
                 $_->{pos} += $pos;
            }
        }

        # merge lines
        $tmp = 0;
        for my $node ( sort { $a->{pos}<=>$b->{pos} } @tbound ) {
            #my $latlon = join q{,}, reverse @{$node->{point}};
            #$nodes->{$latlon} = $latlon;

            if ( $node->{type} eq 'start' ) {
                $tmp = $node;
                $coast->{$tmp->{line}}->[0] = $tmp->{point};
            }
            if ( $node->{type} eq 'bound'  &&  $tmp ) {
                unshift @{$coast->{$tmp->{line}}}, ($tmp->{point});
            }
            if ( $node->{type} eq 'end'  &&  $tmp ) {
                $coast->{$node->{line}}->[-1] = $tmp->{point};
                if ( $node->{line} eq $tmp->{line} ) {
                    push @{$coast->{$node->{line}}}, $coast->{$node->{line}}->[0];
                } else {
                    push @{$coast->{$node->{line}}}, @{$coast->{$tmp->{line}}};
                    delete $coast->{$tmp->{line}};
                    for ( grep { $_->{line} && $tmp->{line} && $_->{line} eq $tmp->{line} } @tbound ) {
                        $_->{line} = $node->{line};
                    }
                }
                $tmp = 0;
            }
        }
    }

    ##  detecting lakes and islands
    my %lake;
    my %island;

    while ( my ($key, $chain) = each %$coast ) {
        next if !($chain->[0] ~~ $chain->[-1]);

        # filter huge polygons to avoid cgpsmapper's crash
        #if ( $hugesea && scalar @$chain_ref > $hugesea ) {
        #    report( sprintf( "Skipped too big coastline $loop (%d nodes)", scalar @$chain_ref ), 'WARNING' );
        #    next;
        #}

        if ( !Math::Polygon->new( @$chain )->isClockwise() ) {
            $island{$key} = 1;
        }
        else {
            #$lake{$key} = Math::Polygon::Tree->new( [ map { [ reverse split q{,}, $nodes->{$_} ] } @$chain_ref ] );
            $lake{$key} = Math::Polygon::Tree->new( $chain );
        }
    }

    my @lakesort = sort { scalar @{$coast->{$b}} <=> scalar @{$coast->{$a}} } keys %lake;

    ##  adding sea background
    if ( $opt{water_background} && @$bound && !$boundcross ) {
        $lake{background} = Math::Polygon::Tree->new( @$bound );
        unshift @lakesort, 'background';
    }

    ##  writing
    #my $countislands = 0;
    my @result;
    for my $sea_key ( @lakesort ) {
        my @poly = $coast->{$sea_key};
        #my %objinfo = (
        #        type    => $config{types}->{sea}->{type},
        #        level_h => $config{types}->{sea}->{endlevel},
        #        comment => "sea $sea",
        #        areas   => $sea eq 'background'
        #            ?  [ \@bound ]
        #            :  [[ map { [ reverse split q{,} ] } @$nodes{@{$coast{$sea}}} ]],
        #    );

        for my $island_key ( keys %island ) {
            if ( $lake{$sea_key}->contains( $coast->{$island_key}->[0] ) ) {
                #$countislands ++;
                push @poly, $coast->{$island_key};
                #push @{$objinfo{holes}}, [ map { [ reverse split q{,} ] } @$nodes{@{$coast{$island}}} ];
                delete $island{$island_key};
            }
        }
        #WritePolygon( \%objinfo );
        push @result, \@poly;
    }

    #printf STDERR "%d lakes, %d islands\n", scalar keys %lake, $countislands;

    return @result;
}




sub _segment_length {
  my ($p1,$p2) = @_;
  return sqrt( ($p2->[0] - $p1->[0])**2 + ($p2->[1] - $p1->[1])**2 );
}


sub _segment_intersection {
    my ($p11, $p12, $p21, $p22) = @_;

    my $Z  = ($p12->[1]-$p11->[1]) * ($p21->[0]-$p22->[0]) - ($p21->[1]-$p22->[1]) * ($p12->[0]-$p11->[0]);
    my $Ca = ($p12->[1]-$p11->[1]) * ($p21->[0]-$p11->[0]) - ($p21->[1]-$p11->[1]) * ($p12->[0]-$p11->[0]);
    my $Cb = ($p21->[1]-$p11->[1]) * ($p21->[0]-$p22->[0]) - ($p21->[1]-$p22->[1]) * ($p21->[0]-$p11->[0]);

    return  if  $Z == 0;

    my $Ua = $Ca / $Z;
    my $Ub = $Cb / $Z;

    return  if  $Ua < 0  ||  $Ua > 1  ||  $Ub < 0  ||  $Ub > 1;

    return [ $p11->[0] + ( $p12->[0] - $p11->[0] ) * $Ub,
             $p11->[1] + ( $p12->[1] - $p11->[1] ) * $Ub ];
}


1;

