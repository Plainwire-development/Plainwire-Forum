.PHONY: deps run shell release clean

deps:
	rebar3 get-deps

run:
	rebar3 shell --apps plainwire_forum

shell:
	rebar3 shell --apps plainwire_forum

release:
	rebar3 as prod release

clean:
	rebar3 clean
	rm -rf _build
