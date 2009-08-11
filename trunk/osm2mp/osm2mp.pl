#!/usr/bin/perl


##
##  Required packages: 
##    * Template-toolkit
##    * Getopt::Long
##    * Text::Unidecode
##    * Math::Polygon
##    * Math::Geometry::Planar::GPC::Polygon
##
##  See http://cpan.org/ or use PPM (Perl package manager) or CPAN module
##

##
##  Licenced under GPL v2
##



use strict;

use Template;
use Getopt::Long;

use Encode;
use Text::Unidecode;
use List::Util qw{ first };

use Math::Polygon;
use Math::Geometry::Planar::GPC::Polygon;

# debug
use Data::Dump;





####    Settings

my $version = "0.80.-1";

my $cfgpoi          = "poi.cfg";
my $cfgpoly         = "poly.cfg";
my $cfgheader       = "header.tpl";

my $mapid           = "88888888";
my $mapname         = "OSM";

my $codepage        = "1251";
my $nocodepage      = 0;

my $detectdupes     = 1;

my $routing         = 1;
my $mergeroads      = 1;
my $mergecos        = 0.2;
my $splitroads      = 1;
my $fixclosenodes   = 1;
my $fixclosedist    = 3.0;       # set 5.5 for cgpsmapper 0097 and earlier
my $maxroadnodes    = 30;
my $restrictions    = 1;
my $disableuturns   = 0;

my $upcase          = 0;
my $translit        = 0;
my $ttable          = "";

my $bbox;
my $bpolyfile;
my $osmbbox         = 0;
my $background      = 0;

my $shorelines      = 0;
my $navitel         = 0;
my $makepoi         = 1;

my $defaultcountry  = "Earth";
my $defaultregion   = "OSM";
my $defaultcity     = "";


my $nametaglist     = "name,ref,int_ref,addr:housenumber";

# ??? make command-line parameters?
my @housenamelist   = qw{ addr:housenumber addr:housename };
my @citynamelist    = qw{ place_name name };
my @regionnamelist  = qw{ addr:region is_in:region addr:state is_in:state };
my @countrynamelist = qw{ addr:country is_in:country_code is_in:country };


my %yesno = (
    "yes"            => '1',
    "true"           => '1',
    "1"              => '1',
    "permissive"     => '1',
    "no"             => '0',
    "false"          => '0',
    "0"              => '0',
    "private"        => '0',
);

GetOptions (
    "cfgpoi=s"          => \$cfgpoi,
    "cfgpoly=s"         => \$cfgpoly,
    "header=s"          => \$cfgheader,
    "mapid=s"           => \$mapid,
    "mapname=s"         => \$mapname,
    "codepage=s"        => \$codepage,
    "nocodepage"        => \$nocodepage,
    "routing!"          => \$routing,
    "mergeroads!"       => \$mergeroads,
    "mergecos=f"        => \$mergecos,
    "detectdupes!"      => \$detectdupes,
    "splitroads!"       => \$splitroads,
    "fixclosenodes!"    => \$fixclosenodes,
    "fixclosedist=f"    => \$fixclosedist,
    "maxroadnodes=f"    => \$maxroadnodes,
    "restrictions!"     => \$restrictions,
    "defaultcountry=s"  => \$defaultcountry,
    "defaultregion=s"   => \$defaultregion,
    "defaultcity=s"     => \$defaultcity,
    "nametaglist=s"     => \$nametaglist,
    "upcase!"           => \$upcase,
    "translit!"         => \$translit,
    "ttable=s"          => \$ttable,
    "bbox=s"            => \$bbox,
    "bpoly=s"           => \$bpolyfile,
    "osmbbox!"          => \$osmbbox,
    "background!",      => \$background,
    "disableuturns!",   => \$disableuturns,
    "shorelines!",      => \$shorelines,
    "navitel!",         => \$navitel,
    "makepoi!",         => \$makepoi,
);

undef $codepage   if $nocodepage;

our %cmap;
do $ttable        if $ttable;

my @nametagarray = split q{,}, $nametaglist;




####    Action

print STDERR "\n  ---|   OSM -> MP converter  $version   (c) 2008,2009  liosha, xliosha\@gmail.com\n\n";

usage() unless (@ARGV);




####    Reading configs

my %poitype;

open CFG, $cfgpoi;
while (<CFG>) {
    next   if (!$_) || /^\s*[\#\;]/;
    chomp;
    my ($k, $v, $type, $llev, $hlev, $city) = split /\s+/;
    if ($type) {
        $llev = 0   if $llev eq "";
        $hlev = 1   if $hlev eq "";
        $city = ($city ne "") ? 1 : 0;
        $poitype{"$k=$v"} = [ $type, $llev, $hlev, $city ];
    }
}
close CFG;



my %polytype;

open CFG, $cfgpoly;
while (<CFG>) {
    next   if (!$_) || /^\s*[\#\;]/;
    chomp;
    my $prio = 0;
    my ($k, $v, $mode, $type, $llev, $hlev, $rp, @p) = split /\s+/;

    if ($type) {
        if ($type =~ /(.+),(\d)/) {
            $type = $1;
            $prio = $2;
        }
        $llev = 0   if ($llev eq "");
        $hlev = 1   if ($hlev eq "");

     $polytype{"$k=$v"} = [ $mode, $type, $prio, $llev, $hlev, $rp ];
   }
}
close CFG;




####    Header

my $tmpl = Template->new( { ABSOLUTE => 1 } );
$tmpl->process ($cfgheader, {
    mapid           => $mapid,
    mapname         => $mapname,
    codepage        => $codepage,
    routing         => $routing,
    defaultcountry  => $defaultcountry,
    defaultregion   => $defaultregion,
}) 
or die $tmpl->error();




####    Info

use POSIX qw{ strftime };
print "\n; Converted from OpenStreetMap data with  osm2mp $version  (" . strftime ("%Y-%m-%d %H:%M:%S", localtime) . ")\n\n";


my ($infile) = @ARGV;
open IN, $infile;
print STDERR "Processing file $infile\n\n";




####    Bounds

my $bounds;
my $boundpoly;
my ($minlon, $minlat, $maxlon, $maxlat);


if ($bbox) {
    $bounds = 1 ;
    ($minlon, $minlat, $maxlon, $maxlat) = split /,/, $bbox;
    $boundpoly = Math::Polygon->new( [$minlon,$minlat],[$maxlon,$minlat],[$maxlon,$maxlat],[$minlon,$maxlat],[$minlon,$minlat] );
}

if ($bpolyfile) {
    $bbox = 0;
    $bounds = 1;

    my @bpoints;

    open (PF, $bpolyfile) 
        or die "Could not open file: $bpolyfile: $!";

    ## ??? need advanced polygon?
    while (<PF>) {
        if (/^\d/) {
            @bpoints = ();
        } 
        elsif (/^\s+([0-9.E+-]+)\s+([0-9.E+-]+)/) {
            push @bpoints, [$1,$2];
        }
        elsif (/^END/) {
            $boundpoly = Math::Polygon->new( @bpoints );
        }
    }
    close (PF);
}


####    1st pass 
###     loading nodes

my %node;
my ( $waypos, $relpos ) = ( 0, 0 );

print STDERR "Loading nodes...          ";

while ( my $line = <IN> ) {

    if ( $line =~ /<node.* id=["']([^"']+)["'].* lat=["']([^"']+)["'].* lon=["']([^"']+)["']/ ) {
        $node{$1} = "$2,$3";
        next;
    }

    if ( $osmbbox  &&  $line =~ /<bounds?/ ) {
        if ( $line =~ /<bounds/ ) {
            ($minlat, $minlon, $maxlat, $maxlon) 
                = ( $line =~ /minlat=["']([^"']+)["'] minlon=["']([^"']+)["'] maxlat=["']([^"']+)["'] maxlon=["']([^"']+)["']/ );
        } 
        else {
            ($minlat, $minlon, $maxlat, $maxlon) 
                = ( $line =~ /box=["']([^"',]+),([^"',]+),([^"',]+),([^"']+)["']/ );
        }
        $bbox = join ",", ($minlon, $minlat, $maxlon, $maxlat);
        $bounds = 1     if $bbox;
        $boundpoly = Math::Polygon->new( [$minlon,$minlat],[$maxlon,$minlat],[$maxlon,$maxlat],[$minlon,$maxlat],[$minlon,$minlat] );
    }

    last    if $line =~ /<way/;
}
continue { $waypos = tell IN }


printf STDERR "%d loaded\n", scalar keys %node;


my $boundgpc = Math::Geometry::Planar::GPC::Polygon->new();
$boundgpc->add_polygon ( [$boundpoly->points()], 0 )    if $bounds;





###     loading relations

# multipolygons
my %mpoly;
my %mphole;

# turn restrictions
my %trest;
my %nodetr;


print STDERR "Loading relations...      ";

my $relid;
my $reltype;

my $mp_outer;
my @mp_inner;

my ($tr_from, $tr_via, $tr_to, $tr_type);


while ( <IN> ) {
    last if /<relation/;
}
continue { $relpos = tell IN }
seek IN, $relpos, 0;


while ( my $line = <IN> ) {

    if ( $line =~ /<relation/ ) {
        ($relid)  =  $line =~ / id=["']([^"']+)["']/;

        undef $reltype;
        undef $mp_outer;
        undef @mp_inner;
        
        undef $tr_type;
        undef $tr_from;
        undef $tr_to;
        undef $tr_via;

        next;
    }

    if ( $line =~ /<member/ ) {
        my ($mtype, $mid, $mrole)  = 
            $line =~ / type=["']([^"']+)["'].* ref=["']([^"']+)["'].* role=["']([^"']+)["']/;

        $mp_outer   = $mid      if  $mtype eq "way"  &&  $mrole eq "outer";
        push @mp_inner, $mid    if  $mtype eq "way"  &&  $mrole eq "inner";

        $tr_from    = $mid      if  $mtype eq "way"  &&  $mrole eq "from";
        $tr_to      = $mid      if  $mtype eq "way"  &&  $mrole eq "to";
        $tr_via     = $mid      if  $mtype eq "node" &&  $mrole eq "via";

        next;
    }

    if ( $line =~ /<tag/ ) {
        my ($key, $val)  =  $line =~ / k=["']([^"']+)["'].* v=["']([^"']+)["']/;
        $reltype = $val         if  $key eq "type";
        $tr_type = $val         if  $key eq "restriction";
        next;
    }

    if ( $line =~ /<\/relation/ ) {
        if ( $reltype eq "multipolygon" ) {
            $mpoly{$mp_outer}   = [ @mp_inner ];
            for my $hole (@mp_inner) {
                $mphole{$hole} = 1;
            }
        }
        if ( $routing  &&  $restrictions  &&  $reltype eq "restriction" ) {
            $tr_to = $tr_from       if  $tr_type eq "no_u_turn"  &&  !$tr_to;

            if ( $tr_from && $tr_via && $tr_to ) {
                $trest{$relid} = { 
                    node    => $tr_via,
                    type    => ($tr_type =~ /^only_/) ? "only" : "no",
                    fr_way  => $tr_from,
                    fr_dir  => 0,
                    fr_pos  => -1,
                    to_way  => $tr_to,
                    to_dir  => 0,
                    to_pos  => -1,
                };
                push @{$nodetr{$tr_via}}, $relid;
            } 
            else {
                print "; ERROR: Incomplete restriction RelID=$relid\n";
            }
        }
        next;
    }

}

printf STDERR "%d multipolygons, %d turn restrictions\n", scalar keys %mpoly, scalar keys %trest;





####    2nd pass
###     loading cities, multipolygon holes and checking node dupes

my %city;

print STDERR "Loading cities...         ";

my $wayid;
my %waytag;
my @chain;
my $dupcount;

seek IN, $waypos, 0;

while ( my $line = <IN> ) {

    if ( $line =~/<way / ) {
        ($wayid)  = $line =~ / id=["']([^"']+)["']/;
        @chain    = ();
        %waytag   = ();
        $dupcount = 0;
        next;
    }

    if ( $line =~ /<nd/ ) {
        my ($ref)  =  $line =~ / ref=["']([^"']+)["']/;
        if ( $node{$ref} ) {
            if ( $ref ne $chain[-1] ) {
                push @chain, $ref;
            }
            else {
                print "; ERROR: WayID=$wayid has dupes at ($node{$ref})\n";
                $dupcount ++;
            }
        }
        next;
    }

   if ( $line =~ /<tag.* k=["']([^"']+)["'].* v=["']([^"']+)["']/ ) {
       $waytag{$1} = $2;
       next;
   }

   if ( $line =~ /<\/way/ ) {

       ##       this way is multipolygon inner
       if ( $mphole{$wayid} ) {
           $mphole{$wayid} = [ @chain ];
       }

       ##       this way is city bound
       if ( $waytag{"place"} eq "city"  ||  $waytag{"place"} eq "town" ) { 
           my $name = convert_string ( first {defined} @waytag{@citynamelist} );

           if ( $name  &&  $chain[0] eq $chain[-1] ) {
               print "; Found city: WayID=$wayid - $name\n";
               $city{$wayid} = {
                    name        =>  $name,
                    region      =>  convert_string( first {defined} @waytag{@regionnamelist} ),
                    country     =>  convert_string( first {defined} @waytag{@countrynamelist} ),
                    bound       =>  Math::Polygon->new( map { [ split q{,}, $node{$_} ] } @chain ),
               };
           } else {
               print "; ERROR: City without name WayID=$wayid\n"            unless  $name;
               print "; ERROR: City polygon WayID=$wayid is not closed\n"   if  $chain[0] ne $chain[-1];
           }
       }
       next;
   }

   last  if $line =~ /<relation/;
}

printf STDERR "%d loaded\n", scalar keys %city;





####    3rd pass
###     writing POIs

print STDERR "Writing POIs...           ";

print "\n\n\n; ### Points\n\n";

my $countpoi = 0;
my $nodeid;
my %nodetag;

seek IN, 0, 0;

while ( my $line = <IN> ) {

    if ( $line =~ /<node/ ) {
        ($nodeid)  =  $line =~ / id=["']([^"']+)["']/;
        %nodetag   =  ();
        next;
    }

    if ( $line =~ /<tag/ ) {
        my ($key, $val)  =  $line =~ / k=["']([^"']+)["'].* v=["']([^"']+)["']/;
        $nodetag{$key}   =  $val;
        next;
    }

    if ( $line =~ /<\/node/ ) {

        my $poitag = first { $poitype{"$_=$nodetag{$_}"} } keys %nodetag;
        next  unless  $poitag;
        next  unless  !$bounds || is_inside_bounds( $node{$nodeid} );

        $countpoi ++;
        my $poi = "$poitag=$nodetag{$poitag}";
        my $poiname = convert_string( first {defined} @nodetag{@nametagarray} );
        my ($type, $llev, $hlev, $iscity) = @{$poitype{$poi}};

        print  "; NodeID = $nodeid\n";
        print  "; $poi\n";
        print  "[POI]\n";
        print  "Type=$type\n";
        printf "Data%d=($node{$nodeid})\n",    $llev;
        printf "EndLevel=%d\n",                 $hlev       if  $hlev > $llev;
        printf "City=Y\n",                                  if  $iscity;
        print  "Label=$poiname\n"                           if  $poiname;

        for my $city (values %city) {
            if ( $city->{bound}->contains( [ split q{,}, $node{$nodeid} ] ) ) {
                print "CityName="    . $city->{name}     . "\n";
                print "RegionName="  . $city->{region}   . "\n"      if  $city->{region};
                print "CountryName=" . $city->{country}  . "\n"      if  $city->{country};
                last;
            } elsif ( $defaultcity ) {
                print "CityName=$defaultcity\n";
            }
        }

        my $housenumber = convert_string( first {defined} @nodetag{@housenamelist} );
        print  "HouseNumber=$housenumber\n"                                     if $housenumber;
        printf "StreetDesc=%s\n", convert_string( $nodetag{'addr:street'} )     if $nodetag{'addr:street'};
        printf "Zip=%s\n",        convert_string( $nodetag{'addr:postcode'} )   if $nodetag{'addr:postcode'};
        printf "Phone=%s\n",      convert_string( $nodetag{'phone'} )           if $nodetag{'phone'};

        print  "[END]\n\n";
    }

    last  if  $line =~ /<way/;
}

printf STDERR "%d written\n", $countpoi;





####    Loading roads and coastlines, and writing other ways

my %road;
my %coast;

my %xnode;

print STDERR "Processing ways...        ";

print "\n\n\n; ### Lines and polygons\n\n";

my $countlines    = 0;
my $countpolygons = 0;

my $wayid;
my $city;
my @chain;
my @chainlist;
my $inbounds;

seek IN, $waypos, 0;

while ( my $line = <IN> ) {

    if ( $line =~ /<way/ ) {
        ($wayid)  =  $line =~ / id=["']([^"']+)["']/;

        %waytag       = ();
        @chain        = ();
        @chainlist    = ();
        $inbounds     = 0;
        $city         = 0;

        next;
    }

    if ( $line =~ /<nd/ ) {
        my ($ref)  =  $line =~ / ref=["']([^"']*)["']/;
        if ( $node{$ref}  &&  $ref ne $chain[-1] ) {
            push @chain, $ref;
            if ($bounds) {
                my $in = is_inside_bounds( $node{$ref} );
                if ( !$inbounds &&  $in )   { push @chainlist, ($#chain ? $#chain-1 : 0); }
                if (  $inbounds && !$in )   { push @chainlist, $#chain; }
                $inbounds = $in;
            }
        }
        next;
    }

    if ( $line =~ /<tag/ ) {
        $line =~ / k=["']([^"']*)["'].* v=["']([^"']*)["']/;
        $waytag{$1} = $2;
        next;
    }

    if ( $line =~ /<\/way/ ) {

        my $poly  =  ( sort { $polytype{$b}->[2] <=> $polytype{$a}->[2] }  grep { exists $polytype{$_} }  map {"$_=$waytag{$_}"} keys %waytag )[0];
        next  unless $poly;

        my ($mode, $type, $prio, $llev, $hlev, $rp) = @{$polytype{$poly}};

        my $name = convert_string( first {defined} @waytag{@nametagarray} );

        @chainlist = (0)            unless $bounds;
        push @chainlist, $#chain    unless ($#chainlist % 2);


        ##  this way is map line - dump it

        if ( $mode eq 'l'  ||  $mode eq 's'  || ( !$routing && $mode eq 'r' ) ) {
            if ( scalar @chain < 2 ) {
                print "; ERROR: WayID=$wayid has too few nodes at ($node{$chain[0]})\n";
                next;
            }

            for ( my $i = 0;  $i < $#chainlist+1;  $i += 2 ) {
                $countlines ++;

                print  "; WayID = $wayid\n";
                print  "; $poly\n";
                print  "[POLYLINE]\n";
                printf "Type=%s\n",         $type;
                printf "EndLevel=%d\n",     $hlev       if  $hlev > $llev;
                print  "Label=$name\n"                  if  $name;
                printf "Data%d=(%s)\n",     $llev, join( q{), (}, @node{@chain[$chainlist[$i]..$chainlist[$i+1]]} );
                print  "[END]\n\n\n";
            }
        }


        ##  this way is coastline - load it

        if ( $mode eq "s"  &&  $shorelines ) {
            if ( scalar @chain < 2 ) {
                print "; ERROR: WayID=$wayid has too few nodes at ($node{$chain[0]})\n";
            } 
            else {
                for ( my $i = 0;  $i < $#chainlist+1;  $i += 2 ) {
                    $coast{$chain[$chainlist[$i]]} = [ @chain[$chainlist[$i]..$chainlist[$i+1]] ];
                }
            }
        }


        ##  this way is map polygon - clip it and dump

        if ( $mode eq "p" ) {
            if ( scalar @chain <= 3 ) {
                print "; ERROR: area WayID=$wayid has too few nodes near ($node{$chain[0]})\n";
                next;
            }

            if ( $chain[0] ne $chain[-1] ) {
                print "; ERROR: area WayID=$wayid is not closed at ($node{$chain[0]})\n";
            }

            print  "; WayID = $wayid\n";
            print  "; $poly\n";

            if ( !$bounds  ||  scalar @chainlist ) {

                if ( $navitel  ||  ($makepoi && $rp && $name) ) {
                    for my $i (keys %city) {
                        if ( $city{$i}->{bound}->contains( [ split q{,}, $node{$chain[0]} ] ) ) {
                            $city = $i;
                            last;
                        }
                    }
                }

                my $gpc = Math::Geometry::Planar::GPC::Polygon->new();
                $gpc->add_polygon( [ map { [reverse split q{,}, $node{$_}] } @chain ], 0 );

                if ( $mpoly{$wayid} ) {
                    for my $hole ( @{$mpoly{$wayid}} ) {
                        if ( $mphole{$hole} ne $hole  &&  ref $mphole{$hole} ) {
                            $gpc->add_polygon( [ map { [reverse split q{,}, $node{$_}] } @{$mphole{$hole}} ], 1 );
                        }
                    }
                }

                if ($bounds) {
                    $gpc = $gpc->clip_to( $boundgpc, 'INTERSECT' );
                }
               

                my @plist  =  sort  { $#{$b} <=> $#{$a} }  $gpc->get_polygons();
                if ( @plist ) {
                    $countpolygons ++;

                    print  "[POLYGON]\n";
                    printf "Type=%s\n",        $type;
                    printf "EndLevel=%d\n",    $hlev    if  $hlev > $llev;
                    print  "Label=$name\n"              if  $name;


                    ## Navitel
                    if ( $navitel ) {
                        my $housenumber = convert_string( first {defined} @waytag{@housenamelist} );
                        if ( $housenumber && $waytag{'addr:street'} ) {
                            print  "HouseNumber=$housenumber\n";
                            printf "StreetDesc=%s\n", convert_string( $waytag{'addr:street'} );
                            if ( $city ) {
                                print "CityName="    . $city{$city}->{name}      . "\n";
                                print "RegionName="  . $city{$city}->{region}    . "\n"      if $city{$city}->{region};
                                print "CountryName=" . $city{$city}->{country}   . "\n"      if $city{$city}->{country};
                            } 
                            elsif ( $defaultcity ) {
                                print "CityName=$defaultcity\n";
                            }
                        }
                    }
            
                    for my $polygon ( @plist ) {
                        printf "Data%d=(%s)\n", $llev, join( q{), (}, map {join( q{,}, reverse @{$_} )} @{$polygon} );
                    }
            
                    print "[END]\n\n\n";
            

                    if ( $makepoi && $rp && $name ) {
            
                        my ($poi, $pll, $phl) = split q{,}, $rp;
            
                        print  "[POI]\n";
                        print  "Type=$poi\n";
                        print  "EndLevel=$phl\n";
                        print  "Label=$name\n";
                        printf "Data%d=(%f,%f)\n", $pll, centroid( @{$plist[0]} );
            
                        my $housenumber = convert_string ( first {defined} @waytag{@housenamelist} );
                        if ( $housenumber && $waytag{'addr:street'} ) {
                            print  "HouseNumber=$housenumber\n";
                            printf "StreetDesc=%s\n", convert_string( $waytag{'addr:street'} );
                            if ( $city ) {
                                print "CityName="    . $city{$city}->{name}      . "\n";
                                print "RegionName="  . $city{$city}->{region}    . "\n"      if $city{$city}->{region};
                                print "CountryName=" . $city{$city}->{country}   . "\n"      if $city{$city}->{country};
                            } 
                            elsif ( $defaultcity ) {
                                print "CityName=$defaultcity\n";
                            }
                        }
            
                        print  "[END]\n\n\n";
                    }
                }
            }
        }


        ##  this way is road - load

        if ( $mode eq "r"  &&  $routing ) {
            if ( scalar @chain <= 1 ) {
                print "; ERROR: Road WayID=$wayid has too few nodes at ($node{$chain[0]})\n";
                next;
            }


            # set routing parameters and access rules
            # RouteParams=speed,class,oneway,toll,emergency,delivery,car,bus,taxi,foot,bike,truck
            my @rp = split q{,}, $rp;

            if ( $waytag{'maxspeed'} > 0 ) {
               $waytag{'maxspeed'} *= 1.61      if  $waytag{'maxspeed'} =~ /mph$/i;
               $rp[0]  = speed_code( $waytag{'maxspeed'} );
            }

            $rp[2] = $yesno{$waytag{'oneway'}}                                    if exists $yesno{$waytag{'oneway'}};

            $rp[3] = $yesno{$waytag{'toll'}}                                      if exists $yesno{$waytag{'toll'}};

            # emergency, delivery, car, bus, taxi, foot, bike, truck
            @rp[4,5,6,7,8,9,10,11]  =  (1-$yesno{$waytag{'access'}})        x 8   if exists $yesno{$waytag{'access'}};
            @rp[          9,10,  ]  =  (  $yesno{$waytag{'motorroad'}})     x 8   if exists $yesno{$waytag{'motorroad'}};

            @rp[4,5,6,7,8,  10,11]  =  (1-$yesno{$waytag{'vehicle'}})       x 8   if exists $yesno{$waytag{'vehicle'}};
            @rp[4,5,6,7,8,     11]  =  (1-$yesno{$waytag{'motor_vehicle'}}) x 8   if exists $yesno{$waytag{'motor_vehicle'}};
            @rp[4,5,6,7,8,     11]  =  (1-$yesno{$waytag{'motorcar'}})      x 8   if exists $yesno{$waytag{'motorcar'}};
            @rp[4,5,6,7,8,     11]  =  (1-$yesno{$waytag{'auto'}})          x 8   if exists $yesno{$waytag{'auto'}};

            @rp[          9,     ]  =  (1-$yesno{$waytag{'foot'}})          x 1   if exists $yesno{$waytag{'foot'}};
            @rp[            10,  ]  =  (1-$yesno{$waytag{'bicycle'}})       x 1   if exists $yesno{$waytag{'bicycle'}};
            @rp[      7,8,       ]  =  (1-$yesno{$waytag{'psv'}})           x 2   if exists $yesno{$waytag{'psv'}};
            @rp[               11]  =  (1-$yesno{$waytag{'hgv'}})           x 1   if exists $yesno{$waytag{'hgv'}};
            @rp[  5,             ]  =  (1-$yesno{$waytag{'goods'}})         x 1   if exists $yesno{$waytag{'goods'}};


            # determine city
            if ( $name ) {
                for my $i ( keys %city ) {
                    if ( $city{$i}->{bound}->contains( [split q{,}, $node{$chain[0]}] ) 
                      && $city{$i}->{bound}->contains( [split q{,} ,$node{$chain[-1]}] ) ) {
                        $city = $i;
                        last;
                    }
                }
            }

            # load roads and external nodes
            for ( my $i = 0;  $i < $#chainlist;  $i += 2 ) {
                $road{"$wayid:$i"} = {
                    type    =>  $poly,
                    name    =>  $name,
                    chain   =>  [ @chain[$chainlist[$i]..$chainlist[$i+1]] ],
                    city    =>  $city,
                    rp      =>  join( q{,}, @rp ),
                };

                if ( $bounds ) {
                    if ( !is_inside_bounds( $node{$chain[$chainlist[$i]]} ) ) {
                        $xnode{ $chain[$chainlist[$i]]   }    = 1;
                        $xnode{ $chain[$chainlist[$i]+1] }    = 1;
                    }
                    if ( !is_inside_bounds( $node{$chain[$chainlist[$i+1]]} ) ) {
                        $xnode{ $chain[$chainlist[$i+1]]   }  = 1;
                        $xnode{ $chain[$chainlist[$i+1]-1] }  = 1;
                    }
                }
            }

            # process associated turn restrictions
            if ($restrictions) {
                if ( $chainlist[0] == 0 ) {
                    for my $relid ( grep { $trest{$_}->{fr_way} eq $wayid } @{$nodetr{$chain[0]}} ) {
                        $trest{$relid}->{fr_way} = "$wayid:0";
                        $trest{$relid}->{fr_dir} = -1;
                        $trest{$relid}->{fr_pos} = 0;
                    }
                    for my $relid ( grep { $trest{$_}->{to_way} eq $wayid } @{$nodetr{$chain[0]}} ) {
                        $trest{$relid}->{to_way} = "$wayid:0";
                        $trest{$relid}->{to_dir} = 1;
                        $trest{$relid}->{to_pos} = 0;
                    }
                }
                if ( $chainlist[-1] == $#chain ) {
                    for my $relid ( grep { $trest{$_}->{fr_way} eq $wayid } @{$nodetr{$chain[-1]}} ) {
                        $trest{$relid}->{fr_way} = "$wayid:" . ($#chainlist-1);
                        $trest{$relid}->{fr_dir} = 1;
                        $trest{$relid}->{fr_pos} = $chainlist[-1] - $chainlist[-2];
                    }
                    for my $relid ( grep { $trest{$_}->{to_way} eq $wayid } @{$nodetr{$chain[-1]}} ) {
                        $trest{$relid}->{to_way} = "$wayid:" . ($#chainlist-1);
                        $trest{$relid}->{to_dir} = -1;
                        $trest{$relid}->{to_pos} = $chainlist[-1] - $chainlist[-2];
                    }
                }
            }
        } # if road
    } # </way>

    last  if $line =~ /<relation/;
}

print  STDERR "$countlines lines and $countpolygons polygons dumped\n";
printf STDERR "                          %d roads loaded\n",      scalar keys %road     if  $routing;
printf STDERR "                          %d coastlines loaded\n", scalar keys %coast    if  $shorelines;





####    Processing coastlines

if ( $shorelines ) {

    print "\n\n\n";
    print STDERR "Processing shorelines...  ";


    ##  merging
    my @keys = keys %coast;
    my $i = 0;
    while ($i < scalar @keys) {
        while (    $coast{$keys[$i]}  
                && $coast{$coast{$keys[$i]}->[-1]}  
                && $coast{$keys[$i]}->[-1] ne $keys[$i] 
                && ( !$bounds  ||  is_inside_bounds( $node{$coast{$keys[$i]}->[-1]} ) ) ) {
            my $mnode = $coast{$keys[$i]}->[-1];
            pop  @{$coast{$keys[$i]}};
            push @{$coast{$keys[$i]}}, @{$coast{$mnode}};
            delete $coast{$mnode};
        }
        $i++;
    }


    ##  tracing bounds
    if ($bounds) {

        my @bound = $boundpoly->points();
        my @tbound;
        my $pos = 0;

        for ( my $i = 0;  $i < $#bound;  $i++ ) {

            push @tbound, {
                type    =>  'bound', 
                point   =>  $bound[$i], 
                pos     =>  $pos
            };

            for my $sline ( keys %coast ) {

                # check start of coastline
                my $p1      = [ reverse  split q{,}, $node{$coast{$sline}->[0]} ];
                my $p2      = [ reverse  split q{,}, $node{$coast{$sline}->[1]} ];
                my $ipoint  = SegmentIntersection( [ $bound[$i], $bound[$i+1], $p1, $p2 ] );

                use Data::Dump;


                unless ( $ipoint ) {
                    if ( DistanceToSegment( [ $bound[$i], $bound[$i+1], $p1 ] ) == 0 ) {
                        $ipoint = $p1;
                    }
                    if ( DistanceToSegment( [ $bound[$i], $bound[$i+1], $p2 ] ) == 0 
                      && !is_inside_bounds( $node{$coast{$sline}->[0]} ) ) {
                        $ipoint = $p2;
                    }
                }

                if ( $ipoint ) {
                    if ( grep { $_->{type} eq 'end'  &&  $_->{point} ~~ $ipoint } @tbound ) {
                        @tbound = grep { !( $_->{type} eq 'end'  &&  $_->{point} ~~ $ipoint ) } @tbound;
                    } 
                    else { 
                        push @tbound, {
                            type    =>  'start', 
                            point   =>  $ipoint, 
                            pos     =>  $pos + SegmentLength( [$bound[$i],$ipoint] ), 
                            line    =>  $sline,
                        };
                    }
                }

                # check end of coastline
                my $p1      = [ reverse  split q{,}, $node{$coast{$sline}->[-1]} ];
                my $p2      = [ reverse  split q{,}, $node{$coast{$sline}->[-2]} ];
                my $ipoint  = SegmentIntersection( [ $bound[$i], $bound[$i+1], $p1, $p2 ] );

                unless ( $ipoint ) {
                    if ( DistanceToSegment( [ $bound[$i], $bound[$i+1], $p1 ] ) == 0 ) {
                        $ipoint = $p1;
                    }
                    if ( DistanceToSegment( [ $bound[$i], $bound[$i+1], $p2 ] ) == 0 
                      && !is_inside_bounds( $node{$coast{$sline}->[-1]} ) ) {
                        $ipoint = $p2;
                    }
                }

                if ( $ipoint ) {
                    if ( grep { $_->{type} eq 'start'  &&  $_->{point} ~~ $ipoint } @tbound ) {
                        @tbound = grep { !( $_->{type} eq 'start'  &&  $_->{point} ~~ $ipoint ) } @tbound;
                    } 
                    else { 
                        push @tbound, {
                            type    =>  'end', 
                            point   =>  $ipoint, 
                            pos     =>  $pos + SegmentLength( [$bound[$i],$ipoint] ), 
                            line    =>  $sline,
                        };
                    }
                }
            }

            $pos += SegmentLength( [ $bound[$i], $bound[$i+1] ] );
        }

        # rotate if sea at $tbound[0]
        my $tmp = ( sort { $a->{pos}<=>$b->{pos} }  grep { $_->{type} ne 'bound' } @tbound )[0];
        if ( $tmp->{type} eq 'end' ) {
            for ( grep { $_->{pos} <= $tmp->{pos} } @tbound ) {
                 $_->{pos} += $pos;
            }
        }

        # merge lines
        my $tmp = 0;
        for my $node ( sort { $a->{pos}<=>$b->{pos} } @tbound ) {
            my $latlon = join q{,}, reverse @{$node->{point}};
            $node{$latlon} = $latlon;

            if ( $node->{type} eq 'start' ) {
                $tmp = $node;
                $coast{$tmp->{line}}->[0] = $latlon;
            } 
            if ( $node->{type} eq 'bound'  &&  $tmp ) {
                unshift @{$coast{$tmp->{line}}}, ($latlon);
            } 
            if ( $node->{type} eq 'end'  &&  $tmp ) {
                $coast{$node->{line}}->[-1] = $latlon;
                if ( $node->{line} eq $tmp->{line} ) {
                    push @{$coast{$node->{line}}}, $coast{$node->{line}}->[0];
                } else {
                    push @{$coast{$node->{line}}}, @{$coast{$tmp->{line}}};
                    for ( grep { $_->{line} eq $tmp->{line} } @tbound ) {
                        $_->{line} = $node->{line};
                    }
                }
                $tmp = 0;
            }
        }
    }


    ##  detecting lakes and islands
    my %loop;
    my %island;

    for my $loop ( grep { $coast{$_}->[0] eq $coast{$_}->[-1] } keys %coast ) {

        # filter huge polygons to avoid cgpsmapper's crash
        next if scalar @{$coast{$loop}} > 30000;

        $loop{$loop} = Math::Polygon->new( map { [ split q{,}, $node{$_} ] } @{$coast{$loop}} );
        if ( $loop{$loop}->isClockwise ) {
            $island{$loop} = 1;
            delete $loop{$loop};
        } 
    }

    
    ##  writing
    my $countislands = 0;
    for my $sea ( keys %loop ) {
        print  "; sea $sea\n";
        print  "[POLYGON]\n";
        print  "Type=0x3c\n";
        print  "EndLevel=4\n";
        printf "Data0=(%s)\n",  join ( q{), (}, @node{@{$coast{$sea}}} );
        
        for my $island  ( keys %island ) {
            if ( $loop{$sea}->contains( [ split q{,}, $node{$island} ] ) ) {
                $countislands ++;
                printf "Data0=(%s)\n",  join ( q{), (}, @node{@{$coast{$island}}} );
                delete $island{$island};
            }
        }
        
        print  "[END]\n\n\n";

    }

    printf STDERR "%d lakes, %d islands\n", scalar keys %loop, $countislands;
}




####    Process roads

my %nodid;
my %roadid;
my %nodeways;

if ( $routing ) {

    ###     detecting end nodes

    my %enode;
    my %rstart;

    while ( my ($roadid, $road) = each %road ) {
        $enode{$road->{chain}->[0]}  ++;
        $enode{$road->{chain}->[-1]} ++;
        $rstart{$road->{chain}->[0]}->{$roadid} = 1;
    }



    ###     merging roads

    if ( $mergeroads ) {
        print "\n\n\n";
        print STDERR "Merging roads...          ";
    
        my $countmerg = 0;
        my @keys = keys %road;
    
        my $i = 0;
        while ($i < scalar @keys) {
            
            my $r1 = $keys[$i];

            unless ( exists $road{$r1} )        {  $i++;  next;  }

            my $p1 = $road{$r1}->{chain};
    
            my @list = ();
            for my $r2 ( keys %{$rstart{$p1->[-1]}} ) {
                if ( $r1 ne $r2  
                  && $road{$r1}->{name} eq $road{$r2}->{name}
                  && $road{$r1}->{city} eq $road{$r2}->{city}
                  && $road{$r1}->{rp}   eq $road{$r2}->{rp}
                  && lcos( $p1->[-2], $p1->[-1], $road{$r2}->{chain}->[1] ) > $mergecos ) {
                    push @list, $r2;
                }
            }

            # merging
            if ( @list ) {
                $countmerg ++;
                @list  =  sort {  lcos( $p1->[-2], $p1->[-1], $road{$b}->{chain}->[1] ) 
                              <=> lcos( $p1->[-2], $p1->[-1], $road{$a}->{chain}->[1] )  }  @list;

                printf "; FIX: Road WayID=$r1 may be merged with %s at (%s)\n", join ( q{, }, @list ), $node{$p1->[-1]};
    
                my $r2 = $list[0];
    
                # process associated restrictions
                if ( $restrictions ) {
                    while ( my ($relid, $tr) = each %trest )  {
                        if ( $tr->{fr_way} eq $r2 )  {
                            print "; FIX: RelID=$relid FROM moved from WayID=$r2 to WayID=$r1\n";
                            $tr->{fr_way} = $r1;
                            $tr->{fr_pos} += ( scalar @{$road{$r1}->{chain}} - 1 );
                        }
                        if ( $tr->{to_way} eq $r2 )  {
                            print "; FIX: RelID=$relid FROM moved from WayID=$r2 to WayID=$r1\n";
                            $tr->{to_way} = $r1;
                            $tr->{to_pos} += ( scalar @{$road{$r1}->{chain}} - 1 );
                        }
                    }
                }
    
                $enode{$road{$r2}->{chain}->[0]} -= 2;
                pop  @{$road{$r1}->{chain}};
                push @{$road{$r1}->{chain}}, @{$road{$r2}->{chain}};
    
                delete $rstart{ $road{$r2}->{chain}->[0] }->{$r2};
                delete $road{$r2};
    
            } else {
                $i ++;
            }
        }
    
        print STDERR "$countmerg merged\n";
    }





    ###    generating routing graph

    my %rnode;

    print STDERR "Detecting road nodes...   ";

    while (my ($roadid, $road) = each %road) {
        for my $node (@{$road->{chain}}) {
            $rnode{$node} ++;
            push @{$nodeways{$node}}, $roadid
                if ( $nodetr{$node}  ||  ( $disableuturns && $enode{$node}==2 ) );
        }
    }

    my $nodcount = 1;
    my $utcount  = 0;

    for my $node ( keys %rnode ) {
        if (  $rnode{$node} > 1  ||  $enode{$node}  ||  $xnode{$node} 
          ||  exists $nodetr{$node}  &&  scalar @{$nodetr{$node}} ) {
            $nodid{$node} = $nodcount++;
        }
        
        if ( $disableuturns  &&  $rnode{$node} == 2  &&  $enode{$node} == 2 ) {
            if ( $road{ $nodeways{$node}->[0] }->{rp}  =~  /^.,.,0/ ) {
                my $pos = indexof( $road{ $nodeways{$node}->[0] }->{chain}, $node);
                $trest{ 'ut'.$utcount++ } = { 
                    node    => $node,
                    type    => 'no',
                    fr_way  => $nodeways{$node}->[0],
                    fr_dir  => $pos > 0  ?   1  :  -1,
                    fr_pos  => $pos,
                    to_way  => $nodeways{$node}->[0],
                    to_dir  => $pos > 0  ?  -1  :   1,
                    to_pos  => $pos,
                };
            }
            if ( $road{ $nodeways{$node}->[1] }->{rp}  =~  /^.,.,0/ ) {
                my $pos = indexof( $road{ $nodeways{$node}->[1] }->{chain}, $node);
                $trest{ 'ut'.$utcount++ } = {
                    node    => $node,
                    type    => 'no',
                    fr_way  => $nodeways{$node}->[1],
                    fr_dir  => $pos > 0  ?   1  :  -1,
                    fr_pos  => $pos,
                    to_way  => $nodeways{$node}->[1],
                    to_dir  => $pos > 0  ?  -1  :   1,
                    to_pos  => $pos,
                };
            }
        }
    }

    undef %rnode;

    printf STDERR "%d found\n", scalar keys %nodid;





    ###    detecting duplicate road segments


    if ( $detectdupes ) {

        my %segway;
    
        print STDERR "Detecting duplicates...   ";
        
        print "\n\n\n; ### Duplicate roads\n\n";
    
        while ( my ($roadid, $road) = each %road ) {
            for ( my $i = 0;  $i < $#{$road->{chain}};  $i ++ ) {
                if (  $nodid{ $road->{chain}->[$i] } 
                  &&  $nodid{ $road->{chain}->[$i+1] } ) {
                    my $seg = join q{:}, sort {$a cmp $b} ($road->{chain}->[$i], $road->{chain}->[$i+1]);
                    push @{$segway{$seg}}, $roadid;
                }
            }
        }
    
        my $countdupsegs  = 0;
    
        my %roadseg;
        my %roadpos;
    
        for my $seg ( grep { $#{$segway{$_}} > 0 }  keys %segway ) {
            $countdupsegs ++;
            my $roads    =  join q{, }, sort {$a cmp $b} @{$segway{$seg}};
            my ($point)  =  split q{:}, $seg;
            $roadseg{$roads} ++;
            $roadpos{$roads} = $node{$point};
        }
    
        for my $road ( keys %roadseg ) {
            printf "; ERROR: Roads $road has $roadseg{$road} duplicate segments near ($roadpos{$road})\n";
        }
    
        printf STDERR "$countdupsegs segments, %d roads\n", scalar keys %roadseg;
    }




    ####    fixing self-intersections and long roads

    if ( $splitroads ) {

        print STDERR "Splitting roads...        ";

        print "\n\n\n";
        
        my $countself = 0;
        my $countlong = 0;
        
        while ( my ($roadid, $road) = each %road ) {
            my $break   = 0;
            my @breaks  = ();
            my $rnod    = 1;
            my $prev    = 0;

            for ( my $i = 1;  $i < scalar @{$road->{chain}};  $i++ ) {
                $rnod ++    if  $nodid{ $road->{chain}->[$i] };

                if ( grep { $_ eq $road->{chain}->[$i] } @{$road->{chain}}[$break..$i-1] ) {
                    $countself ++;
                    if ( $road->{chain}->[$i] ne $road->{chain}->[$prev] ) {
                        $break = $prev;
                        push @breaks, $break;
                    } else {
                        $break = ($i + $prev) >> 1;
                        push @breaks, $break;
                        $nodid{ $road->{chain}->[$break] }  =  $nodcount++;
                        printf "; FIX: Added NodID=%d for NodeID=%s at (%s)\n", 
                            $nodid{ $road->{chain}->[$break] },
                            $road->{chain}->[$break],
                            $node{$road->{chain}->[$break]};
                    }
                    $rnod = 1;
                }

                if ( $rnod == $maxroadnodes ) {
                    $countlong ++;
                    $break = $prev;
                    push @breaks, $break;
                    $rnod = 1;
                }

                $prev = $i      if  $nodid{ $road->{chain}->[$i] };
            }

            if ( @breaks ) {
                printf "; FIX: WayID=$road is splitted at %s\n", join( q{, }, @breaks );
                push @breaks, $#{$road->{chain}};

                for ( my $i = 0;  $i < $#breaks;  $i++ ) {
                    my $id = $roadid.'/'.($i+1);
                    printf "; FIX: Added road %s, nodes from %d to %d\n", $id, $breaks[$i], $breaks[$i+1];
                    
                    $road{$id} = {
                        chain   => [ @{$road->{chain}}[$breaks[$i] .. $breaks[$i+1]] ],
                        type    => $road{$roadid}->{type},
                        name    => $road{$roadid}->{name},
                        city    => $road{$roadid}->{city},
                        rp      => $road{$roadid}->{rp},
                    };

                    if ( $restrictions ) {
                        while ( my ($relid, $tr) = each %trest )  {
                            if (  $tr->{to_way} eq $roadid 
                              &&  $tr->{to_pos} >  $breaks[$i]   - (1 + $tr->{to_dir}) / 2 
                              &&  $tr->{to_pos} <= $breaks[$i+1] - (1 + $tr->{to_dir}) / 2 ) {
                                $tr->{to_way}  =  $id;
                                $tr->{to_pos}  -= $breaks[$i];
                                print "; FIX: Turn restriction RelID=$relid moved to WayID=$id\n";
                            }
                            if (  $tr->{fr_way} eq $roadid 
                              &&  $tr->{fr_pos} >  $breaks[$i]   + ($tr->{fr_dir} - 1) / 2
                              &&  $tr->{fr_pos} <= $breaks[$i+1] + ($tr->{fr_dir} - 1) / 2 ) {
                                $tr->{fr_way} =  $id;
                                $tr->{fr_pos} -= $breaks[$i];
                                print "; FIX: Turn restriction RelID=$relid moved to WayID=$id\n";
                                
                            }
                        }
                    }
                }
                $#{$road->{chain}} = $breaks[0];
            }
        }
        print STDERR "$countself self-intersections, $countlong long roads\n";
    }
    




    ###    fixing too close nodes

    if ( $fixclosenodes ) {
        
        print "\n\n\n";
        print STDERR "Fixing close nodes...     ";

        my $countclose = 0;
        
        while ( my ($roadid, $road) = each %road ) {
            my $cnode = $road->{chain}->[0];
            for my $node ( grep { $_ ne $cnode && $nodid{$_} } @{$road->{chain}}[1..$#{$road->{chain}}] ) {
                if ( fix_close_nodes( $cnode, $node ) ) {
                    $countclose ++;
                    print "; ERROR: too close nodes $cnode and $node, WayID=$roadid near (${node{$node}})\n";
                }
                $cnode = $node;
            }
        }
        print STDERR "$countclose pairs fixed\n";
    }




    ###    dumping roads


    print STDERR "Writing roads...          ";

    print "\n\n\n; ### Roads\n\n";

    my $roadcount = 1;
    
    while ( my ($roadid, $road) = each %road ) {

        my ($poly, $name, $rp) = ($road->{type}, $road->{name}, $road->{rp});
        my ($mode, $type, $prio, $llev, $hlev)  =  @{$polytype{$poly}};
        
        $roadid{$roadid} = $roadcount++;
        
        #  @type == [ $mode, $type, $prio, $llev, $hlev, $rp ]
        print  "; WayID = $roadid\n";
        print  "; $poly\n";
        print  "[POLYLINE]\n";
        printf "Type=%s\n",         $type;
        printf "EndLevel=%d\n",     $hlev       if  $hlev > $llev;
        print  "Label=$name\n"                  if  $name;
        print  "StreetDesc=$name\n"             if  $name  &&  $navitel;
        print  "DirIndicator=1\n"               if  $rp =~ /^.,.,1/;

        printf "Data%d=(%s)\n",     $llev, join( q{), (}, @node{@{$road->{chain}}} );
        printf "RoadID=%d\n",       $roadid{$roadid};
        printf "RouteParams=%s\n",  $rp;
        
        if ( $road->{city} ) {
            my $rcity = $city{$road->{city}};
            print "CityName=$rcity->{name}\n";
            print "RegionName=$rcity->{region}\n"       if ($rcity->{region});
            print "CountryName=$rcity->{country}\n"     if ($rcity->{country});
        } elsif ( $name  &&  $defaultcity ) {
            print "CityName=$defaultcity\n";
        }
        
        
        my $nodcount = 0;
        for my $i (0..$#{$road->{chain}}) {
            my $node = $road->{chain}->[$i];
            if ( $nodid{$node} ) {
                printf "Nod%d=%d,%d,%d\n", $nodcount++, $i, $nodid{$node}, $xnode{$node};
            }
        }
        
        print  "[END]\n\n\n";
    }

    printf STDERR "%d written\n", $roadcount-1;

} # if $routing



####    Background object (?)


if ( $bounds && $background ) {

    print "\n\n\n; ### Background\n\n";
    print  "[POLYGON]\n";
    print  "Type=0x4b\n";
    print  "EndLevel=4\n";
    printf "Data0=(%s)\n",      join( q{), (},  map { join q{,}, reverse @{$_} } $boundpoly->points() );
    print  "[END]\n\n\n";

}




####    Writing turn restrictions


if ( $routing && $restrictions  ) {

    print "\n\n\n; ### Turn restrictions\n\n";

    print STDERR "Writing restrictions...   ";

    my $counttrest = 0;

    while ( my ($relid, $tr) = each %trest ) {

        unless ( $tr->{fr_dir} ) {
            print "; ERROR: RelID=$relid FROM road does'n have VIA end node\n";
            next;
        }
        unless ( $tr->{to_dir} ) {
            print "; ERROR: RelID=$relid TO road does'n have VIA end node\n";
            next;
        }


        if ( $tr->{type} eq 'no' ) {
            $counttrest ++;
            write_turn_restriction ($tr);
        }

        if ( $tr->{type} eq 'only') {
            my %newtr = (
                    node    => $tr->{node},
                    type    => 'no',
                    fr_way  => $tr->{fr_way},
                    fr_dir  => $tr->{fr_dir},
                    fr_pos  => $tr->{fr_pos}
                );

            for my $roadid ( @{$nodeways{ $trest{$relid}->{node} }} ) {
                print "; To road $roadid \n";
                $newtr{to_way} = $roadid;
                $newtr{to_pos} = indexof( $road{$roadid}->{chain}, $tr->{node} );

                if (  $newtr{to_pos} < $#{$road{$roadid}->{chain}} 
                  &&  !( $tr->{to_way} eq $roadid  &&  $tr->{to_dir} eq 1 ) ) {
                    $newtr{to_dir} = 1;
                    $counttrest ++;
                    write_turn_restriction (\%newtr);
                }

                if (  $newtr{to_pos} > 0 
                  &&  !( $tr->{to_way} eq $roadid  &&  $tr->{to_dir} eq -1 ) 
                  &&  $road{$roadid}->{rp} !~ /^.,.,1/ ) {
                    $newtr{to_dir} = -1;
                    $counttrest ++;
                    write_turn_restriction (\%newtr);
                }
            }
        }
    }

    print STDERR "$counttrest written\n";
}





print STDERR "All done!!\n\n";








####    Functions

sub convert_string {            # String

    my $str = decode("utf8", $_[0]);
   
    unless ( $translit ) {
        for my $repl ( keys %cmap ) {
            $str =~ s/$repl/$cmap{$repl}/g;
        }
    }
    
    $str = unidecode($str)      if $translit;
    $str = uc($str)             if $upcase;
    
    $str = encode( ($nocodepage ? "utf8" : "cp".$codepage), $str );
   
    $str =~ s/\&#(\d+)\;/chr($1)/ge;
    $str =~ s/\&amp\;/\&/gi;
    $str =~ s/\&apos\;/\'/gi;
    $str =~ s/\&quot\;/\"/gi;
    $str =~ s/\&[\d\w]+\;//gi;
   
    $str =~ s/[\?\"\<\>\*]/ /g;
    $str =~ s/[\x00-\x1F]//g;
   
    $str =~ s/^[ \`\'\;\.\,\!\-\+\_]+//;
    $str =~ s/ +/ /g;
    $str =~ s/\s+$//;
    
    return $str;
}



sub fix_close_nodes {                # NodeID1, NodeID2

    my ($lat1, $lon1) = split ",", $node{$_[0]};
    my ($lat2, $lon2) = split ",", $node{$_[1]};

    my ($clat, $clon) = ( ($lat1+$lat2)/2, ($lon1+$lon2)/2 );
    my ($dlat, $dlon) = ( ($lat2-$lat1),   ($lon2-$lon1)   );
    my $klon = cos( $clat * 3.14159 / 180 );

    my $ldist = $fixclosedist * 180 / 20_000_000;

    my $res = ($dlat**2 + ($dlon*$klon)**2) < $ldist**2;

    # fixing
    if ( $res ) {
        if ( $dlon == 0 ) {
            $node{$_[0]} = ($clat - $ldist/2 * ($dlat==0 ? 1 : ($dlat <=> 0) )) . q{,} . $clon;
            $node{$_[1]} = ($clat + $ldist/2 * ($dlat==0 ? 1 : ($dlat <=> 0) )) . q{,} . $clon;
        }
        else {
            my $azim  = $dlat / $dlon;
            my $ndlon = sqrt( $ldist**2 / ($klon**2 + $azim**2) ) / 2;
            my $ndlat = $ndlon * abs($azim);

            $node{$_[0]} = ($clat - $ndlat * ($dlat <=> 0)) . q{,} . ($clon - $ndlon * ($dlon <=> 0));
            $node{$_[1]} = ($clat + $ndlat * ($dlat <=> 0)) . q{,} . ($clon + $ndlon * ($dlon <=> 0));
        }
    }
    return $res;
}



sub lcos {                      # NodeID1, NodeID2, NodeID3

    my ($lat1, $lon1) = split q{,}, $node{$_[0]};
    my ($lat2, $lon2) = split q{,}, $node{$_[1]};
    my ($lat3, $lon3) = split q{,}, $node{$_[2]};

    my $klon = cos( ($lat1+$lat2+$lat3) / 3 * 3.14159 / 180 );

    my $xx = (($lat2-$lat1)**2+($lon2-$lon1)**2*$klon**2) * (($lat3-$lat2)**2+($lon3-$lon2)**2*$klon**2);

    return -1   if ( $xx == 0);
    return (($lat2-$lat1)*($lat3-$lat2)+($lon2-$lon1)*($lon3-$lon2)*$klon**2) / sqrt($xx);
}



sub speed_code {                 # $speed
    my ($spd) = @_;
    return 7        if $spd >= 110;
    return 6        if $spd >= 90;
    return 5        if $spd >= 80;
    return 4        if $spd >= 60;
    return 3        if $spd >= 40;
    return 2        if $spd >= 20;
    return 1        if $spd >= 10;
    return 0;
}


sub is_inside_bbox {                # $latlon
    my ($lat, $lon) = split q{,}, $_[0];
    return  ( $lat > $minlat  &&  $lon > $minlon  &&  $lat < $maxlat  &&  $lon < $maxlon );
}


sub is_inside_bounds {                # $latlon
    return is_inside_bbox( @_ )     if  $bbox;
    return $boundpoly->contains( [ reverse split q{,}, $_[0] ] );
}


sub write_turn_restriction {                 # \%trest

    my ($tr) = @_;

    my $i = $tr->{fr_pos} - $tr->{fr_dir};
    while ( !$nodid{ $road{$tr->{fr_way}}->{chain}->[$i] }  &&  $i >= 0  &&  $i < $#{$road{$tr->{fr_way}}->{chain}} ) {
        $i -= $tr->{fr_dir};
    }
    
    my $j = $tr->{to_pos} + $tr->{to_dir};
    while ( !$nodid{ $road{$tr->{to_way}}->{chain}->[$j] }  &&  $j >= 0  &&  $j < $#{$road{$tr->{to_way}}->{chain}} ) {
        $j += $tr->{to_dir};
    }

    unless ( ${nodid{$tr->{node}}} ) {
        print "; Restriction is outside boundaries\n";
        return;
    }
    
    print  "[Restrict]\n";
    printf "Nod=${nodid{$tr->{node}}}\n";
    print  "TraffPoints=${nodid{$road{$tr->{fr_way}}->{chain}->[$i]}},${nodid{$tr->{node}}},${nodid{$road{$tr->{to_way}}->{chain}->[$j]}}\n";
    print  "TraffRoads=${roadid{$tr->{fr_way}}},${roadid{$tr->{to_way}}}\n";
    print  "Time=\n";
    print  "[END-Restrict]\n\n";
}


sub centroid {

    my $slat = 0;
    my $slon = 0;
    my $ssq  = 0;

    for (my $i = 1; $i < scalar(@_) - 1; $i++ ) {
        my $tlat = ($_[0]->[0]+$_[$i]->[0]+$_[$i+1]->[0])/3;
        my $tlon = ($_[0]->[1]+$_[$i]->[1]+$_[$i+1]->[1])/3;

        my $tsq = (($_[$i]->[0]-$_[0]->[0])*($_[$i+1]->[1]-$_[0]->[1]) - ($_[$i+1]->[0]-$_[0]->[0])*($_[$i]->[1]-$_[0]->[1]));
        
        $slat += $tlat * $tsq;
        $slon += $tlon * $tsq;
        $ssq  += $tsq;
    }

#    return ($slat/$ssq , $slon/$ssq);
    return ($slon/$ssq , $slat/$ssq);
}


sub usage  {

    my @onoff = ( "off", "on");

    print "Usage:  osm2mp.pl [options] file.osm > file.mp

Possible options [defaults]:

    --mapid <id>              map id            [$mapid]
    --mapname <name>          map name          [$mapname]

    --cfgpoi <file>           poi config        [$cfgpoi]
    --cfgpoly <file>          way config        [$cfgpoly]
    --header <file>           header template   [$cfgheader]

    --bbox <bbox>             comma-separated minlon,minlat,maxlon,maxlat
    --osmbbox                 use bounds from .osm              [$onoff[$osmbbox]]
    --bpoly <poly-file>       use bounding polygon from .poly-file

    --background              create background object          [$onoff[$background]]

    --codepage <num>          codepage number                   [$codepage]
    --nocodepage              leave all labels in utf-8         [$onoff[$nocodepage]]
    --upcase                  convert all labels to upper case  [$onoff[$upcase]]
    --translit                tranliterate labels               [$onoff[$translit]]
    --ttable <file>           character conversion table

    --nametaglist <list>      comma-separated list of tags for Label    [$nametaglist]
    --defaultcountry <name>   default data for street indexing  [$defaultcountry]
    --defaultregion <name>                                      [$defaultregion]
    --defaultcity <name>                                        [$defaultcity]
    --navitel                 write addresses for polygons              [$onoff[$navitel]]

    --routing                 produce routable map                      [$onoff[$routing]]
    --mergeroads              merge same ways                           [$onoff[$mergeroads]]
    --mergecos <cosine>       maximum allowed angle between roads to merge      [$mergecos]
    --splitroads              split long and self-intersecting roads    [$onoff[$splitroads]]
    --fixclosenodes           enlarge distance between too close nodes  [$onoff[$fixclosenodes]]
    --fixclosedist <dist>     minimum allowed distance                  [$fixclosedist m]
    --maxroadnodes <dist>     maximum number of nodes in road segment   [$maxroadnodes]
    --detectdupes             detect road duplicates                    [$onoff[$detectdupes]]

    --restrictions            process turn restrictions                 [$onoff[$restrictions]]
    --disableuturns           disable u-turns on nodes with 2 links     [$onoff[$disableuturns]]

    --shorelines              process shorelines                        [$onoff[$shorelines]]
    --makepoi                 create POIs for polygons                  [$onoff[$makepoi]]


You can use no<option> disable features (i.e --nomergeroads)
";
    exit;
}



sub indexof {                   # \@array, $elem

    return -1   if ( !defined($_[0]) );
    for (my $i=0; $i < scalar @{$_[0]}; $i++)
        { return $i if ($_[0]->[$i] eq $_[1]); }
    return -1;
}

####    Functions from Math::Geometry::Planar
##      should be optimised!


use Carp;

################################################################################
#  
#  The determinant for the matrix  | x1 y1 |
#                                  | x2 y2 |
#
# args : x1,y1,x2,y2
#
sub Determinant {
  my ($x1,$y1,$x2,$y2) = @_;
  return ($x1*$y2 - $x2*$y1);
}

################################################################################
#
# vector dot product
# calculates dotproduct vectors p1p2 and p3p4
# The dot product of a and b  is written as a.b and is
# defined by a.b = |a|*|b|*cos q 
#
# args : reference to an array with 4 points p1,p2,p3,p4 defining 2 vectors
#        a = vector p1p2 and b = vector p3p4
#        or
#        reference to an array with 3 points p1,p2,p3 defining 2 vectors
#        a = vector p1p2 and b = vector p1p3
#
sub DotProduct {
  my $pointsref = $_[0];
  my @points = @$pointsref;
  my (@p1,@p2,@p3,@p4);
  if (@points == 4) {
    @p1 = @{$points[0]};
    @p2 = @{$points[1]};
    @p3 = @{$points[2]};
    @p4 = @{$points[3]};
  } elsif (@points == 3) {
    @p1 = @{$points[0]};
    @p2 = @{$points[1]};
    @p3 = @{$points[0]};
    @p4 = @{$points[2]};
  } else {
    carp("Need 3 or 4 points for a dot product");
    return;
  }
  return ($p2[0]-$p1[0])*($p4[0]-$p3[0]) + ($p2[1]-$p1[1])*($p4[1]-$p3[1]);
}

################################################################################
#
# returns vector cross product of vectors p1p2 and p1p3
# using Cramer's rule
#
# args : reference to an array with 3 points p1,p2 and p3
#
sub CrossProduct {
  my $pointsref = $_[0];
  my @points = @$pointsref;
  if (@points != 3) {
    carp("Need 3 points for a cross product");
    return;
  }
  my @p1 = @{$points[0]};
  my @p2 = @{$points[1]};
  my @p3 = @{$points[2]};
  my $det_p2p3 = &Determinant($p2[0], $p2[1], $p3[0], $p3[1]);
  my $det_p1p3 = &Determinant($p1[0], $p1[1], $p3[0], $p3[1]);
  my $det_p1p2 = &Determinant($p1[0], $p1[1], $p2[0], $p2[1]);
  return ($det_p2p3-$det_p1p3+$det_p1p2);
}



################################################################################
#
# calculate length of a line segment
#
# args : reference to array with 2 points defining line segment
#
sub SegmentLength {
  my $pointsref = $_[0];
  my @points = @$pointsref;
  if (@points != 2) {
    carp("Need 2 points for a segment length calculation");
    return;
  }
  my @a = @{$points[0]};
  my @b = @{$points[1]};
  my $length = sqrt(DotProduct([$points[0],$points[1],$points[0],$points[1]]));
  return $length;
}

################################################################################
#
# Calculate distance from point p to line segment p1p2
#
# args: reference to array with 3 points: p1,p2,p3
#       p1p2 = segment
#       p3   = point for which distance is to be calculated
# returns distance from p3 to line segment p1p2
#         which is the smallest value from:
#            distance p3p1
#            distance p3p2
#            perpendicular distance from p3 to line p1p2
#
sub DistanceToSegment {
  my $pointsref = $_[0];
  my @points = @$pointsref;
  if (@points < 3) {
    carp("DistanceToSegment needs 3 points defining a segment and a point");
    return;
  }
  # the perpendicular distance is the height of the parallelogram defined
  # by the 3 points devided by the base
  # Note the this is a signed value so it can be used to check at which
  # side the point is located
  # we use dot products to find out where point is located1G/dotpro
  my $d1 = DotProduct([$points[0],$points[1],$points[0],$points[2]]);
  my $d2 = DotProduct([$points[0],$points[1],$points[0],$points[1]]);
  my $dp = CrossProduct([$points[2],$points[0],$points[1]]) / sqrt $d2;
  if ($d1 <= 0) {
    return SegmentLength([$points[2],$points[0]]);
  } elsif ($d2 <= $d1) {
    return SegmentLength([$points[2],$points[1]]);
  } else {
    return $dp;
  }
}



################################################################################
#
# calculate intersection point of 2 line segments
# returns false if segments don't intersect
# The theory:
#
#  Parametric representation of a line
#    if p1 (x1,y1) and p2 (x2,y2) are 2 points on a line and
#       P1 is the vector from (0,0) to (x1,y1)
#       P2 is the vector from (0,0) to (x2,y2)
#    then the parametric representation of the line is P = P1 + k (P2 - P1)
#    where k is an arbitrary scalar constant.
#    for a point on the line segement (p1,p2)  value of k is between 0 and 1
#
#  for the 2 line segements we get
#      Pa = P1 + k (P2 - P1)
#      Pb = P3 + l (P4 - P3)
#
#  For the intersection point Pa = Pb so we get the following equations
#      x1 + k (x2 - x1) = x3 + l (x4 - x3)
#      y1 + k (y2 - y1) = y3 + l (y4 - y3)
#  Which using Cramer's Rule results in
#          (x4 - x3)(y1 - y3) - (y4 - x3)(x1 - x3)
#      k = ---------------------------------------
#          (y4 - y3)(x2 - x1) - (x4 - x3)(y2 - y1)
#   and
#          (x2 - x1)(y1 - y3) - (y2 - y1)(x1 - x3)
#      l = ---------------------------------------
#          (y4 - y3)(x2 - x1) - (x4 - x3)(y2 - y1)
#
#  Note that the denominators are equal.  If the denominator is 9,
#  the lines are parallel.  Intersection is detected by checking if
#  both k and l are between 0 and 1.
#
#  The intersection point p5 (x5,y5) is:
#     x5 = x1 + k (x2 - x1)
#     y5 = y1 + k (y2 - y1)
#
# 'Touching' segments are considered as not intersecting
#
# args : reference to an array with 4 points p1,p2,p3,p4
#
sub SegmentIntersection {
  my $pointsref = $_[0];
  my @points = @$pointsref;
  if (@points != 4) {
    carp("SegmentIntersection needs 4 points");
    return;
  }

  my $precision = 7;
  my $delta = 10 ** (-$precision);
  
  my @p1 = @{$points[0]}; # p1,p2 = segment 1
  my @p2 = @{$points[1]};
  my @p3 = @{$points[2]}; # p3,p4 = segment 2
  my @p4 = @{$points[3]};
  my @p5;
  my $n1 = Determinant(($p3[0]-$p1[0]),($p3[0]-$p4[0]),($p3[1]-$p1[1]),($p3[1]-$p4[1]));
  my $n2 = Determinant(($p2[0]-$p1[0]),($p3[0]-$p1[0]),($p2[1]-$p1[1]),($p3[1]-$p1[1]));
  my $d  = Determinant(($p2[0]-$p1[0]),($p3[0]-$p4[0]),($p2[1]-$p1[1]),($p3[1]-$p4[1]));
  if (abs($d) < $delta) {
    return 0; # parallel
  }
  if (!(($n1/$d < 1) && ($n2/$d < 1) &&
        ($n1/$d > 0) && ($n2/$d > 0))) {
    return 0;
  }
  $p5[0] = $p1[0] + $n1/$d * ($p2[0] - $p1[0]);
  $p5[1] = $p1[1] + $n1/$d * ($p2[1] - $p1[1]);
  return \@p5; # intersection point
}
