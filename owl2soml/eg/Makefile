IGNORE = skos-fix.ttl skos-xl.ttl skos-thes.ttl
TTL    = $(filter-out $(IGNORE), $(wildcard *.ttl))
YAML   = $(patsubst %.ttl, %.yaml, $(TTL))

all : clean $(YAML) SWAPI-lang1.yaml SWAPI-lang2.yaml

clean :
	find . -size 0 -delete

%.yaml : %.ttl
	time perl ../owl2soml.pl $^ $(EXTRA) > $@ 2> $*.log
	time perl ../owl2soml.pl $^ -super 1 $(EXTRA) > $*-super.yaml 2> $*-super.log

SWAPI-lang1.yaml : SWAPI.ttl
	time perl ../owl2soml.pl $^ $(EXTRA) > $@ 2> SWAPI-lang1.log

SWAPI-lang2.yaml : SWAPI.ttl
	time perl ../owl2soml.pl $^ $(EXTRA) > $@ 2> SWAPI-lang2.log

SWAPI.yaml              : EXTRA = -id swapi -name rdfs:label
SWAPI-lang1.yaml        : EXTRA = -id swapi -name rdfs:label -lang en
SWAPI-lang2.yaml        : EXTRA = -id swapi -name rdfs:label -lang "fetch: en, validate: en,fr;UNIQ, implicit: en"
skos.yaml               : EXTRA = -name skos:prefLabel skos-fix.ttl
gvp.yaml                : EXTRA = skos.ttl skos-fix.ttl skos-xl.ttl # skos-thes.ttl
dct_owldl.yaml          : EXTRA = -voc dcterms
schema.yaml             : EXTRA = -voc schema
schema-all-layers.yaml  : EXTRA = -voc schema
fibo-FND.yaml           : EXTRA = -voc NONE -id fibo-FND -label "FIBO Foundation" 

## Read more bytes than requested. Do you use an encoding-related PerlIO layer?
# schema1.yaml : ../owl2soml.pl schema.rdf
# 	perl ../owl2soml.pl -voc schema schema.rdf > schema1.yaml
