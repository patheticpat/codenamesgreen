package gameapi

import (
	"encoding/json"
	"math/rand"
	"time"
)

type Color int

const (
	Tan Color = iota
	Green
	Black
)

func (c Color) String() string {
	switch c {
	case Green:
		return "g"
	case Black:
		return "b"
	default:
		return "t"
	}
}

func (c Color) MarshalJSON() ([]byte, error) {
	return json.Marshal(c.String())
}

// GameState encapsulates enough data to reconstruct
// a Game's state. It's used to recreate games after
// a process restart.
type GameState struct {
	Seed       int64             `json:"seed"`
	Round      int               `json:"round"`
	ExposedOne []bool            `json:"exposed_one"`
	ExposedTwo []bool            `json:"exposed_two"`
	Players    map[string]Player `json:"players"`
	WordSet    []string          `json:"word_set"`
}

type Player struct {
	Team     int       `json:"team"`
	LastSeen time.Time `json:"last_seen"`
}

func NewState(seed int64, words []string) GameState {
	return GameState{
		Seed:       seed,
		Round:      0,
		ExposedOne: make([]bool, len(colorDistribution)),
		ExposedTwo: make([]bool, len(colorDistribution)),
		Players:    make(map[string]Player),
		WordSet:    words,
	}
}

type Game struct {
	GameState `json:"state"`
	CreatedAt time.Time `json:"created_at"`
	Words     []string  `json:"words"`
	OneLayout []Color   `json:"one_layout"`
	TwoLayout []Color   `json:"two_layout"`
}

func (g *Game) markSeen(playerID string, team int, when time.Time) {
	p, ok := g.Players[playerID]
	if ok {
		p.LastSeen = when
		if team != 0 {
			p.Team = team
		}
		g.Players[playerID] = p
		return
	}
	g.Players[playerID] = Player{Team: team, LastSeen: when}
}

func (g *Game) pruneOldPlayers(now time.Time) {
	for id, player := range g.Players {
		if player.LastSeen.Add(50 * time.Second).Before(now) {
			delete(g.Players, id)
			continue
		}
	}
}

func ReconstructGame(state GameState) (g Game) {
	g = Game{
		GameState: state,
		CreatedAt: time.Now(),
		OneLayout: make([]Color, len(colorDistribution)),
		TwoLayout: make([]Color, len(colorDistribution)),
	}

	rnd := rand.New(rand.NewSource(state.Seed))

	// Pick 25 random words.
	used := make(map[string]bool, len(colorDistribution))
	for len(used) < len(colorDistribution) {
		w := state.WordSet[rnd.Intn(len(state.WordSet))]
		if !used[w] {
			g.Words = append(g.Words, w)
			used[w] = true
		}
	}

	// Assign the colors for each team, according to the
	// relative distribution in the rule book.
	perm := rnd.Perm(len(colorDistribution))
	for i, colors := range colorDistribution {
		g.OneLayout[perm[i]] = colors[0]
		g.TwoLayout[perm[i]] = colors[1]
	}
	return g
}

var colorDistribution = [25][2]Color{
	{Black, Green},
	{Tan, Green},
	{Tan, Green},
	{Tan, Green},
	{Tan, Green},
	{Tan, Green},
	{Green, Green},
	{Green, Green},
	{Green, Green},
	{Green, Tan},
	{Green, Tan},
	{Green, Tan},
	{Green, Tan},
	{Green, Tan},
	{Green, Black},
	{Tan, Black},
	{Black, Black},
	{Tan, Tan},
	{Tan, Tan},
	{Tan, Tan},
	{Tan, Tan},
	{Tan, Tan},
	{Tan, Tan},
	{Tan, Tan},
	{Black, Tan},
}
