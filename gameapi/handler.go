package gameapi

import (
	"encoding/json"
	"fmt"
	"math/rand"
	"net/http"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/jbowens/dictionary"
)

// Handler implements the codenames green server handler.
func Handler(wordLists map[string][]string) http.Handler {
	h := &handler{
		mux:       http.NewServeMux(),
		wordLists: wordLists,
		rand:      rand.New(rand.NewSource(time.Now().UnixNano())),
		games:     make(map[string]*Game),
	}
	h.mux.HandleFunc("/new-game", h.handleNewGame)
	h.mux.HandleFunc("/game-state", h.handleGameState)
	h.mux.HandleFunc("/guess", h.handleGuess)

	// Periodically remove games that are old and inactive.
	go func() {
		for now := range time.Tick(10 * time.Minute) {
			h.mu.Lock()
			for id, g := range h.games {
				g.pruneOldPlayers(now)
				if len(g.Players) > 0 {
					continue // at least one player is still in the game
				}
				if g.CreatedAt.Add(24 * time.Hour).After(time.Now()) {
					continue // hasn't been 24 hours since the game started
				}
				delete(h.games, id)
			}
			h.mu.Unlock()
		}
	}()

	return h
}

type handler struct {
	mux       *http.ServeMux
	wordLists map[string][]string
	rand      *rand.Rand

	mu    sync.Mutex
	games map[string]*Game
}

func (h *handler) ServeHTTP(rw http.ResponseWriter, req *http.Request) {
	// Allow all cross-origin requests.
	header := rw.Header()
	header.Set("Access-Control-Allow-Origin", "*")
	header.Set("Access-Control-Allow-Methods", "*")
	header.Set("Access-Control-Allow-Headers", "Content-Type")
	header.Set("Access-Control-Max-Age", "1728000") // 20 days

	if req.Method == "OPTIONS" {
		rw.WriteHeader(http.StatusOK)
		return
	}
	h.mux.ServeHTTP(rw, req)
}

// POST /new-game
func (h *handler) handleNewGame(rw http.ResponseWriter, req *http.Request) {
	var body struct {
		GameID   string   `json:"game_id"`
		Words    []string `json:"words"`
		PrevSeed *string  `json:"prev_seed"` // a string because of js number precision
	}
	err := json.NewDecoder(req.Body).Decode(&body)
	if err != nil || body.GameID == "" {
		writeError(rw, "malformed_body", "Unable to parse request body.", 400)
		return
	}

	h.mu.Lock()
	defer h.mu.Unlock()

	// If the game already exists, make sure that the request includes
	// the existing game's seed so a delayed request doesn't reset an
	// existing game.
	oldGame, ok := h.games[body.GameID]
	if ok && (body.PrevSeed == nil || *body.PrevSeed != strconv.FormatInt(oldGame.Seed, 10)) {
		writeJSON(rw, oldGame)
		return
	}

	words := body.Words
	if len(words) == 0 {
		words = h.wordLists["green"]
	}
	if len(words) < len(colorDistribution) {
		writeError(rw, "too_few_words",
			fmt.Sprintf("A word list must have at least %d words.", len(colorDistribution)), 400)
		return
	}

	game := ReconstructGame(NewState(h.rand.Int63(), words))
	if oldGame != nil {
		// Carry over the players but without teams in case
		// they want to switch them up.
		for id, p := range oldGame.Players {
			game.Players[id] = Player{LastSeen: p.LastSeen}
		}
	}

	g := &game
	g.CreatedAt = time.Now()
	h.games[body.GameID] = g
	writeJSON(rw, g)
}

// POST /game-state
func (h *handler) handleGameState(rw http.ResponseWriter, req *http.Request) {
	var body struct {
		GameID   string `json:"game_id"`
		PlayerID string `json:"player_id,omitempty"`
		Team     int    `json:"team,omitempty"`
	}
	err := json.NewDecoder(req.Body).Decode(&body)
	if err != nil || body.GameID == "" {
		writeError(rw, "malformed_body", "Unable to parse request body.", 400)
		return
	}

	h.mu.Lock()
	defer h.mu.Unlock()
	g, ok := h.games[body.GameID]
	if !ok {
		writeError(rw, "not_found", "Game not found", 404)
		return
	}
	if body.PlayerID != "" {
		g.markSeen(body.PlayerID, body.Team, time.Now())
	}
	writeJSON(rw, g)
}

// POST /guess
func (h *handler) handleGuess(rw http.ResponseWriter, req *http.Request) {
	var body struct {
		GameID   string `json:"game_id"`
		PlayerID string `json:"player_id"`
		Team     int    `json:"team"`
		Index    int    `json:"index"`
	}

	err := json.NewDecoder(req.Body).Decode(&body)
	if err != nil || body.GameID == "" || body.Team == 0 || body.PlayerID == "" {
		writeError(rw, "malformed_body", "Unable to parse request body.", 400)
		return
	}

	h.mu.Lock()
	defer h.mu.Unlock()
	g, ok := h.games[body.GameID]
	if !ok {
		writeError(rw, "not_found", "Game not found", 404)
		return
	}
	g.markSeen(body.PlayerID, body.Team, time.Now())

	g.markGuess(body.Team, body.Index)

	writeJSON(rw, g)
}

func writeError(rw http.ResponseWriter, code, message string, statusCode int) {
	rw.WriteHeader(statusCode)
	writeJSON(rw, struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	}{Code: code, Message: message})
}

func writeJSON(rw http.ResponseWriter, resp interface{}) {
	j, err := json.Marshal(resp)
	if err != nil {
		http.Error(rw, "unable to marshal response: "+err.Error(), 500)
		return
	}

	rw.Header().Set("Content-Type", "application/json")
	rw.Write(j)
}

func DefaultWordlists() (map[string][]string, error) {
	matches, err := filepath.Glob("wordlists/*txt")
	if err != nil {
		return nil, err
	}

	lists := map[string][]string{}
	for _, m := range matches {
		base := filepath.Base(m)
		name := strings.TrimSuffix(base, filepath.Ext(base))

		d, err := dictionary.Load(m)
		if err != nil {
			return nil, err
		}
		words := d.Words()
		sort.Strings(words)
		lists[name] = words
	}
	return lists, nil
}