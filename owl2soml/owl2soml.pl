#!perl -w

# copied from https://github.com/kasei/attean/blob/master/bin/attean_query
# https://github.com/kasei/attean/issues/149 asks for an easier way

use v5.14;
use warnings;
no warnings 'redefine'; # quash https://github.com/kasei/attean/issues/153 "Subroutine spacepad redefined"
use strict;
use Carp::Always; # use Carp "verbose"
use Attean;
use URI::NamespaceMap;
use List::MoreUtils qw(uniq);
use Array::Utils qw(array_minus);
#use autodie; # https://perldoc.perl.org/5.30.0/autodie.html
#use open ':std', ':encoding(utf8)';
#use Data::Dumper;
use Getopt::Long;

our $store = Attean->get_store('Memory')->new();
our $model = Attean::MutableQuadModel->new(store => $store);
our $graph = Attean::IRI->new('http://example.org/');
our $ontology_iri;                     # as Attean::IRI
our $ontology;                         # $ontology_iri as string
our $vocab_iri;                        # vocab namespace as Attean::IRI
our $vocab_prefix;                     # vocab prefix as string
our $map   = URI::NamespaceMap->new(); # prefixes in loaded ontologies
our $MAP   = URI::NamespaceMap->new    # fixed prefixes used in mapping ("service" namespace)
  ({so     => "http://www.ontotext.com/semantic-object/",
    dc     => "http://purl.org/dc/elements/1.1/",
    dct    => "http://purl.org/dc/terms/",
    owl    => "http://www.w3.org/2002/07/owl#",
    rdf    => "http://www.w3.org/1999/02/22-rdf-syntax-ns#",
    rdfs   => "http://www.w3.org/2000/01/rdf-schema#",
    schema => "http://schema.org/",
    skos   => "http://www.w3.org/2004/02/skos/core#",
    swc    => "http://schema.semantic-web.at/ppt/",
    vann   => "http://purl.org/vocab/vann/preferredNamespaceUri",
    xsd    => "http://www.w3.org/2001/XMLSchema#",
   });
our %iri_name;                  # Mapping (hash, dict) from IRI to GrapQL name
our %soml;                      # The total SOML as hash (dict), see YAML::Dump at the end

# TODO: document how it searches for vocab_iri and vocab_prefix, in particular swc: props
# TODO: document rdfs:subClassOf

our @LABEL_PROPS = qw(rdfs:label skos:prefLabel dc:title dct:title);
our @DESCR_PROPS = qw(rdfs:comment skos:definition skos:description skos:scopeNote dc:description dct:description);
our @CREATOR_PROPS = qw(dc:creator dct:creator); # dc:contributor dct:contributor
our %DATATYPES =
  (# XSD datatypes
   "xsd:string"             => "string",
   "xsd:double"             => "double",
   "xsd:boolean"            => "boolean",
   "xsd:byte"               => "byte",
   "xsd:short"              => "short",
   "xsd:int"                => "int",
   "xsd:long"               => "long",
   "xsd:unsignedLong"       => "unsignedLong",
   "xsd:unsignedInt"        => "unsignedInt",
   "xsd:unsignedShort"      => "unsignedShort",
   "xsd:unsignedByte"       => "unsignedByte",
   "xsd:decimal"            => "decimal",
   "xsd:integer"            => "integer",
   "xsd:positiveInteger"    => "positiveInteger",
   "xsd:nonPositiveInteger" => "nonPositiveInteger",
   "xsd:negativeInteger"    => "negativeInteger",
   "xsd:nonNegativeInteger" => "nonNegativeInteger",
   "xsd:dateTime"           => "dateTime",
   "xsd:time"               => "time",
   "xsd:date"               => "date",
   "xsd:gYear"              => "year",
   "xsd:gYearMonth"         => "yearMonth",
   # other datatypes
   "rdfs:Literal"           => "string",
   "rdf:langString"         => "string",
   "schema:Boolean"         => "boolean",
   "schema:Date"            => "date",
   "schema:DateTime"        => "dateTime",
   "schema:Float"           => "double",
   "schema:Integer"         => "integer",
   "schema:Number"          => "decimal",
   "schema:Text"            => "string",
   "schema:Time"            => "time",
   "schema:URL"             => "iri",
  );

sub my_exit() {
  # quash warnings "(in cleanup) at URI/Namespace.pm line 104 during global destruction"
  $map = $MAP = undef;
  exit
}

sub my_warn($) {
  my $err = shift;
  $err = "$err\n" unless $err =~ /\n$/;
  print STDERR $err;
}

sub my_die($) {
  my_warn(shift);
  my_exit()
}

sub usage () {
  my $label_props   = join", ", @LABEL_PROPS;
  my $descr_props   = join", ", @DESCR_PROPS;
  my $creator_props = join", ", @CREATOR_PROPS;
  my $datatypes = join ", ", sort keys %DATATYPES;
  my_die << "END";
$0 - Generates SOML from supplied ontologies

Usage: $0 ontology.(ttl|rdf) ... > ontology.yaml
Options:
  --vocab pfx     Uses "pfx" as the main vocab_prefix

Parses:
- ontologies (owl:Ontology, dct:created, dct:modified, $creator_props),
- classes (rdfs:Class, owl:Class, EXCLUDES schema:DataType);
- props (rdf:Property, owl:AnnotationProperty, owl:DatatypeProperty, owl:ObjectProperty);
- datatypes (default string; $datatypes);
- prop relations (owl:inverseOf, schema:inverseOf; but NOT rdfs:subPropertyOf);
- prop domains (rdfs:domain, schema:domainIncludes, owl:unionOf). Multiple domains are allowed.
- prop ranges (rdfs:range, schema:rangeIncludes, owl:unionOf). Object or datatype ranges are allowed.
- labels ($label_props),
- descriptions ($descr_props).
- if a range class (eg rdf:List) is not defined in the ontology, it's defined in SOML without any props

Limitations:
- Takes metadata only from the first ("root") owl:Ontology
- Uses only labels/descriptions in "en" (including en-US, en-GB etc) or without language tag
- owl:AnnotationProperty and owl:DatatypeProperty are treated the same
- Doesn't suppport multiple superclasses (the first one is used). Enquire about the status of issue PLATFORM-360
- Doesn't support multiple prop ranges (the first one is used). Enquire about the status of issue PLATFORM-1493
- Doesn't handle owl:import. Instead, provide multiple ontologies on input
- Doesn't strip HTML tags (eg in schema.org property rdfs:comments)
- rdf:langString and rdfs:Literal are mapped to xsd:string
- Some ontologies (eg SKOS) expect that a subProperty inherits domain & range from its ancestors transitively (e.g. all 10 subprops of skos:semanticRelation do not define their own domain & range but inherit it). Such inheritance is defined in OWL 2 Web Ontology Language Profiles, Table 9 The Semantics of Schema Vocabulary (rules https://www.w3.org/TR/owl2-profiles/#scm-dom2, https://www.w3.org/TR/owl2-profiles/#scm-rng2); though not by RDFS semantics (https://www.w3.org/TR/rdf11-mt/#rdfs-entailment). Enquire about the status of issue PLATFORM-1500
END
}

GetOptions ("vocab=s" => \$vocab_prefix) or usage();

sub first_ontology() {
  # get ontology metadata, and try to figure out vocab_iri and vocab_prefix

  my $base;
  my $iter = $model->subjects(IRI("rdf:type"), IRI("owl:Ontology"));
  if ($ontology_iri = $iter->next) {
    $ontology = $ontology_iri->as_string;
    $iter->next and my_warn("Found multiple ontologies, only metadata of the first one $ontology is used");
    $base = one_value($model->objects($ontology_iri, IRI("swc:BaseUrl")))
  };
  # try to find vocab_iri and vocab_prefix in various inter-dependent ways
  if ($vocab_prefix) { # option --vocab $vocab_refix
    $vocab_iri = iri ($map->namespace_uri($vocab_prefix))
      or my_die "can't find vocab_iri of --vocab prefix $vocab_prefix";
  } elsif ($ontology_iri and $vocab_prefix = one_value($model->objects($ontology_iri, IRI("swc:identifier")))) {
    $vocab_iri = iri ($map->namespace_uri($vocab_prefix)) || do {
      $map->add_mapping ($vocab_prefix => "$ontology/");
      iri ("$ontology/");
      # my_die "can't find vocab_iri of swc:identifier '$vocab_prefix'";
      # my_die "--vocab prefix '$vocab_prefix' does not agree with swc:identifier '$vocab_prefix1'" if $vocab_prefix && $vocab_prefix1 && $vocab_prefix ne $vocab_prefix1;
    }
  } elsif ($ontology_iri and $vocab_iri = one_value($model->objects($ontology_iri, IRI("vann:preferredNamespaceUri")))) {
    $vocab_prefix = $map->prefix_for($vocab_iri)
      or my_die "can't find vocab_prefix for vann:preferredNamespaceUri $vocab_iri";
       # TODO: handle vann:preferredNamespacePrefix
      # my_die "iri ".$vocab_iri->as_string." from --vocab prefix does not agree with vann:preferredNamespaceUri $vocab_iri1"
    $vocab_iri = iri ($vocab_iri);
  } elsif ($ontology_iri) { # look for it amongst defined prefixes
    my $ontology_re = qr(^\Q$ontology\E[#/]?$); # ontology IRI, optionally followed by slash or hash
    for ($map->list_namespaces) {
      if ($_->as_string =~ m{$ontology_re}) {
        $vocab_prefix = $map->prefix_for($_);
        $vocab_iri = iri($_);
        last
      }
    };
    $vocab_iri or my_die "can't find vocab_iri for $ontology amongst these namespaces:\n".
      (join"\n", sort map $_->as_string, $map->list_namespaces);
  } else {
    my_die "can't find owl:Ontology (should be in first RDF file) and --vocab prefix not specified"
  };
  $soml{id} = "/soml/$vocab_prefix";
  $soml{specialPrefixes}{vocab_prefix} = $vocab_prefix;
  $soml{specialPrefixes}{vocab_iri}    = $vocab_iri->as_string;
  $soml{specialPrefixes}{ontology_iri} = $ontology if $ontology;
  $soml{specialPrefixes}{base_iri}     = $base if $base;
}

sub load_ontologies(@) {
  my $count = 0;
  while (my $data = shift) {
    # my $base  = Attean::IRI->new('http://example.org/');
    open(my $fh, '<:encoding(UTF-8)', $data) or my_die "can't open $data: $!";
    my $pclass  = Attean->get_parser(filename => $data) // 'AtteanX::Parser::Turtle';
    my $parser  = $pclass->new(namespaces => $map); # base => $base
    my $iter    = $parser->parse_iter_from_io($fh);
    my $quads   = $iter->as_quads($graph);
    $model->add_iter($quads);
    first_ontology() unless $count++
  }
}

sub query_select ($) {
  # NOT USED yet
  my $q = shift;
  my $algebra = Attean->get_parser('SPARQL')->new(namespaces => $map)->parse($q); # base => $base,
  my $default_graphs = [$graph];
  my $plan = Attean::IDPQueryPlanner->new()->plan_for_algebra($algebra, $model, $default_graphs);
  my $mapper = Attean::TermMap->canonicalization_map->binding_mapper; # canonicalizes typed Attean::API::Literals
  my $iter = $plan->evaluate($model)->map($mapper);
  $iter
}

sub uniq_en_strings ($) {
  # in: iterator of Attean::API::Term
  # out: array of IRIs, or strings (have no lang), or langString "@en", skipping duplicates
  my $iter = shift;
  uniq (map $_->value,
        grep !$_->can("has_language") || !$_->has_language || $_->language =~ "^en",
        $iter->elements)
}

sub get_label ($$) {
  # get one label for a node
  my $iri = shift;     # the node whose labels we're fetching: ontology, class or property
  my $message = shift; # error message for the user
  my @labels = uniq_en_strings($model->objects($iri, [map IRI($_), @LABEL_PROPS]));
  my_warn "Found multiple labels for $message, using the first one: ".(join", ",@labels)
    if @labels > 1;
  @labels ? $labels[0] : undef # if any labels, return the 0-th one, else undef
}

sub get_descr ($) {
  # get all descriptions for a node
  my $iri = shift;  # the node whose descriptions we're fetching: ontology, class or property
  my @descr = uniq_en_strings($model->objects($iri, [map IRI($_), @DESCR_PROPS]));
  map {s{\. *$}{}} @descr; # remove trailing dot...
  join ". ", @descr; # ...because we add dot between values
}

sub one_value ($) {
  # return the value of the first (or only) element of iterator of Attean::API::Term
  my $term = shift->next;
  $term && $term->value
}

sub date_part ($) {
  my $dateTime = shift or return;
  $dateTime =~ s{T\d.*$}{}; # substitute: T followed by a digit and any chars; with empty
  $dateTime
}

# https://github.com/kasei/attean/issues/151
# Attean::IRI is not compatible with URI

sub iri ($) {
  # convert string or URI (returned by URI::NamespaceMap $MAP) to Attean::IRI
  my $uri = shift or return;
  Attean::IRI->new (value => ref($uri) ? $uri->as_string : $uri, lazy => 1)
}

sub uri ($) {
  my $iri = shift;
  URI->new (ref($iri) ? $iri->as_string : $iri);
}

sub IRI ($) {
  # Return Attean::IRI from prefixed name resolved through $MAP (the "service" namespace).
  my $pname = shift;
  my $iri = iri($MAP->uri($pname));
  $iri
}

sub iri_name($) {
  # given an IRI, return hash of 3 names:
  #  "gql" (GraphQL), "rdf" (RDF prefixed name), eventually "super" (gql+"Common")
  my $iri = shift;
  return $iri_name{$iri} if $iri_name{$iri}; # memoization
  my $rdf = $map->abbreviate(uri($iri))
    or my_die("No suitable prefix for IRI ".$iri->as_string);
  my $gql = $rdf;
  $gql =~ s{^$vocab_prefix:}{};
  $gql =~ s{[-_.]}{}g;  # FIXME: this is not very comprehensive
  return $iri_name{$iri} = {gql=>$gql, rdf=>$rdf}
}

sub make_superClass ($) {
  # given $iri of a superclass (eg skos:Collection), produce the following configuration:
  #  skos:Collection:
  #    inherits: skos:CollectionCommon
  #    props:
  #      skos:member: {}
  #    type: skos:Collection
  #  skos:CollectionCommon:
  #    kind: abstract
  # TODO: once we implement concrete superclass, simplify this code

  my $iri = shift;
  my $iri_name = iri_name($iri);
  return $iri_name->{super} if $iri_name->{super};
  my $concrete = $iri_name->{gql};
  my $super = $iri_name->{super} = $concrete."Common";
  $soml{objects}{$super}{kind} = "abstract";
  $soml{objects}{$concrete}{inherits} = $super;
  ($super, $concrete)
}

sub expand_union($); # quash "called too early to check prototype" because of recursive call
sub expand_union($) {
  # collect direct objects and union members, eg: schema:domainIncludes :x, :y, [owl:unionOf (:z :t)]
  my $iter = shift;
  my @objects;
  for my $obj ($iter->elements) {
    my $union = $model->objects($obj, IRI("owl:unionOf"))->next;
    push @objects,
      ($union ? expand_union($model->get_list(undef,$union)) : $obj)
  }
  @objects
}

sub map_datatype ($) {
  my $d = shift;
  return unless $d;
  $d = uri($d);
  return unless $d = $MAP->abbreviate($d);
  return $DATATYPES{$d}
}

##### main

scalar(@ARGV) < 1 and usage(); # if there are no args, print usage() and die
load_ontologies(@ARGV);

# prefixes
while (my ($pfx,$iri) = $map->each_map) {
  $soml{prefixes}{$pfx} = $iri->as_string
};

# ontology metadata
if ($ontology_iri) {
  my $label = get_label ($ontology_iri,"ontology");
  $soml{label} = $label if $label;
  my @creators = uniq_en_strings($model->objects($ontology_iri, [map IRI($_), @CREATOR_PROPS]));
  $soml{creator} = join ", ", @creators;
  my $created = date_part (one_value($model->objects($ontology_iri, IRI("dct:created"))));
  $soml{created} = $created if $created;
  my $updated = date_part (one_value($model->objects($ontology_iri, IRI("dct:modified"))));
  $soml{updated} = $updated if $updated;
  my $versionInfo = one_value($model->objects($ontology_iri, IRI("owl:versionInfo")));
  $soml{versionInfo} = $versionInfo if $versionInfo;
}

# classes (objects)

# https://github.com/kasei/attean/issues/152: need to use uniq()
my @classes = uniq ($model->subjects(IRI("rdf:type"), [IRI("rdfs:Class"), IRI("owl:Class")])->elements);
my @no_classes = IRI("schema:DataType"),
  $model->subjects(IRI("rdf:type"), IRI("schema:DataType"))->elements;
# ignore classes that are schema:DataType or blank node
@classes = grep $_->isa("Attean::IRI"), array_minus (@classes, @no_classes);
for my $class (@classes) {
  my $iri_name = iri_name($class);
  my $name = $iri_name->{gql};
  my $rdf = $iri_name->{rdf};
  $soml{objects}{$name}{type} = $rdf if $name ne $rdf; # by default, "type: $name"
  my $label = get_label ($class, "class $rdf");
  $soml{objects}{$name}{label} = $label if $label;
  my $descr = get_descr ($class);
  $soml{objects}{$name}{descr} = $descr if $descr;
  my $superClassIter = $model->objects ($class, IRI("rdfs:subClassOf"));
  if (my $superClass = $superClassIter->next) {
    my ($super1,$super2) = make_superClass($superClass);
    $soml{objects}{$name}{inherits} = $super1;
    my_warn("Multiple superclasses found for $rdf, using only the first one: $super2")
      if $superClassIter->next
    }
};

# properties
for my $prop
  (uniq ($model->subjects
         (IRI("rdf:type"),
          [map IRI($_),
           qw(rdf:Property owl:AnnotationProperty owl:DatatypeProperty owl:ObjectProperty)])
         ->elements)) {
  my $iri_name = iri_name($prop);
  my $name = $iri_name->{gql};
  my $rdf = $iri_name->{rdf};
  $soml{properties}{$name}{rdfProp} = $rdf if $name ne $rdf;
  my $label = get_label ($prop, "property $rdf");
  $soml{properties}{$name}{label} = $label if $label;
  my $descr = get_descr ($prop);
  $soml{properties}{$name}{descr} = $descr if $descr;

  # prop characteristics
  my $isObjectProp = $model->holds ($prop, IRI("rdf:type"), IRI("owl:ObjectProperty"));
  my $isDataProp   = $model->holds ($prop, IRI("rdf:type"), [IRI("owl:AnnotationProperty"), IRI("owl:DatatypeProperty")]);
  my $isSymmetric  = $model->holds ($prop, IRI("rdf:type"), IRI("owl:SymmetricProperty"));
  $soml{properties}{$name}{symmetric} = 1 if $isSymmetric;
  my $isFunctional = $model->holds ($prop, IRI("rdf:type"), IRI("owl:FunctionalProperty"));
  $soml{properties}{$name}{max} = "inf" unless $isFunctional;
  my $inverseOf = one_value ($model->objects ($prop, [IRI("owl:inverseOf"), IRI("schema:inverseOf")]));
  $inverseOf = iri_name($inverseOf)->{gql} if $inverseOf;
  $soml{properties}{$name}{inverseOf} = $inverseOf if $inverseOf;

  # domains
  my @domains = expand_union ($model->objects ($prop, [IRI("rdfs:domain"), IRI("schema:domainIncludes")]));
  for my $domain (@domains) {
    my $class = iri_name($domain)->{gql};
    # fix for referenced classes that may not be defined in the ontology
    $soml{objects}{$class}{type} = iri_name($domain)->{rdf};
    $soml{objects}{$class}{props}{$name} = {};
  };

  # ranges
  my ($datatype, $class);
  my @ranges = expand_union ($model->objects ($prop, [IRI("rdfs:range"), IRI("schema:rangeIncludes")]));
  if (my $range = $ranges[0]) {
    $datatype = map_datatype ($range);
    $class = !$datatype && iri_name($range)->{gql};
    my_warn("Multiple ranges found for prop $name, using only the first one: ".($datatype || $class))
      if @ranges>1;
    # fix for referenced classes that may not be defined in the ontology
    $soml{objects}{$class}{type} = iri_name($range)->{rdf} if $class;
    if ($isObjectProp && $datatype) {my_die("Prop $name is owl:ObjectProperty but has range datatype $datatype")};
    if ($isDataProp   && $class)    {my_die("Prop $name is owl:DatatypeProperty or owl:AnnotationProperty but has range class $class")};
  };
  # defaults: "free-standing" URL vs string
  if (!$datatype && !$class) {
    if ($isObjectProp) {$class = "iri"} else {$datatype = "string"}
  };
  $soml{properties}{$name}{range} = $datatype || $class;
  $soml{properties}{$name}{kind}  = $datatype ?  "literal" : "object";
  ## my_die "prop $name: object=$isObjectProp, data=$isDataProp, class=$class, datatype=$datatype" if $name eq "relation";
};

# print YAML
use YAML; $YAML::UseHeader=0; print YAML::Dump(\%soml);
# use YAML::XS; print YAML::XS::Dump(\%soml); # faster for large files
# use YAML::PP; print YAML::PP::Dump(\%soml); # aims to support "YAML 1.2" and "YAML 1.1".
# use Data::YAML::Writer; Data::YAML::Writer->new->write(\%soml,*STDOUT);
# use YAML::Hobo; print YAML::Hobo::Dump(\%soml); # uses YAML::Tiny
# use YAML::Perl; print YAML::Perl::Dump(\%soml); # still alpha
# use YAML::Dump; print YAML::Dump(\%soml);

my_exit();