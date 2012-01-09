REBAR := ./rebar
ARGS = 
ERL_LIBS := apps:deps
export ERL_LIBS

.PHONY: all deps doc test clean release

all:
	$(REBAR) compile skip_deps=true $(ARGS)

deps:
	$(REBAR) get-deps
	$(REBAR) compile

doc:
	$(REBAR) doc skip_deps=true

test:   all
	$(REBAR) eunit skip_deps=true $(ARGS)

clean:
	$(REBAR) clean skip_deps=true

clean_deps:
	$(REBAR) clean

dialyzer:
	dialyzer -r apps --src

release: deps all
	$(REBAR) generate force=1
