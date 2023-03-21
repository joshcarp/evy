//go:build tinygo

package main

import (
	"strings"

	"foxygo.at/evy/pkg/evaluator"
	"foxygo.at/evy/pkg/parser"
)

var (
	version string
	eval    *evaluator.Evaluator
	events  []evaluator.Event
)

func main() {
	defer afterStop()
	actions := getActions()

	rt := newJSRuntime()
	input := getEvySource()
	ast, err := parse(input, rt)
	if err != nil {
		rt.Print(err.Error())
		return
	}
	if actions["fmt"] {
		formattedInput := ast.Format()
		if formattedInput != input {
			setEvySource(formattedInput)
		}
	}
	if actions["ui"] {
		prepareUI(ast)
	}
	if actions["eval"] {
		// The ast does not correspond to the formatted source code. For
		// now this is acceptable because evaluator errors don't output
		// source code locations.
		evaluate(ast, rt)
	}
}

func getActions() map[string]bool {
	m := map[string]bool{}
	addr := jsActions()
	s := getStringFromAddr(addr)
	actions := strings.Split(s, ",")
	for _, action := range actions {
		if action != "" {
			m[action] = true
		}
	}
	return m
}

func getEvySource() string {
	addr := evySource()
	return getStringFromAddr(addr)
}

func parse(input string, rt evaluator.Runtime) (*parser.Program, error) {
	builtins := evaluator.DefaultBuiltins(rt).ParserBuiltins()
	prog, err := parser.Parse(input, builtins)
	if err != nil {
		return nil, parser.TruncateError(err, 8)
	}
	return prog, nil
}

func prepareUI(prog *parser.Program) {
	funcNames := prog.CalledBuiltinFuncs
	eventHandlerNames := parser.EventHandlerNames(prog.EventHandlers)
	names := append(funcNames, eventHandlerNames...)
	jsPrepareUI(strings.Join(names, ","))
}

func evaluate(prog *parser.Program, rt *jsRuntime) {
	builtins := evaluator.DefaultBuiltins(rt)
	eval = evaluator.NewEvaluator(builtins)
	eval.Eval(prog)
	handleEvents(rt.yielder)
}

func handleEvents(yielder *sleepingYielder) {
	if eval == nil || len(eval.EventHandlerNames()) == 0 {
		return
	}
	for _, name := range eval.EventHandlerNames() {
		registerEventHandler(name)
	}
	for {
		if eval.Stopped {
			return
		}
		// unsynchronized access to events - ok in WASM as single threaded.
		if len(events) > 0 {
			event := events[0]
			events = events[1:]
			yielder.Reset()
			eval.HandleEvent(event)
		} else {
			yielder.ForceYield()
		}
	}
}
