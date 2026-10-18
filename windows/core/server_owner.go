package core

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"net"
)

// Listener is one row of the TCP listener table: the local port and the id
// of the process that owns the socket.
type Listener struct {
	Port int
	PID  int
}

// Row sizes of MIB_TCPTABLE_OWNER_PID (IPv4) and MIB_TCP6TABLE_OWNER_PID
// (IPv6), as returned by GetExtendedTcpTable with TCP_TABLE_OWNER_PID_LISTENER.
const (
	TCPRowOwnerPIDSize  = 24 // state, local addr, local port, remote addr, remote port, pid
	TCP6RowOwnerPIDSize = 56 // local addr[16], scope, port, remote addr[16], scope, port, state, pid
)

// ParseOwnerPIDTable reads the listener table GetExtendedTcpTable wrote into
// buf: a DWORD row count followed by rows of rowSize bytes. Ports are in
// network byte order in the low 16 bits of their DWORD.
func ParseOwnerPIDTable(buf []byte, rowSize int) ([]Listener, error) {
	var portOff, pidOff int
	switch rowSize {
	case TCPRowOwnerPIDSize:
		portOff, pidOff = 8, 20
	case TCP6RowOwnerPIDSize:
		portOff, pidOff = 20, 52
	default:
		return nil, fmt.Errorf("unknown row size %d", rowSize)
	}
	if len(buf) < 4 {
		return nil, errors.New("short table")
	}
	n := int(binary.LittleEndian.Uint32(buf))
	if n < 0 || n > (len(buf)-4)/rowSize {
		return nil, fmt.Errorf("table holds %d rows but has room for %d", n, (len(buf)-4)/rowSize)
	}
	out := make([]Listener, 0, n)
	for i := 0; i < n; i++ {
		row := buf[4+i*rowSize : 4+(i+1)*rowSize]
		out = append(out, Listener{
			Port: int(binary.BigEndian.Uint16(row[portOff : portOff+2])),
			PID:  int(binary.LittleEndian.Uint32(row[pidOff : pidOff+4])),
		})
	}
	return out, nil
}

// FreeLoopbackPort asks the system for a free TCP port on 127.0.0.1. Koe
// starts whisper-server on a new port every time instead of a fixed one.
func FreeLoopbackPort() (int, error) {
	l, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	port := l.Addr().(*net.TCPAddr).Port
	if err := l.Close(); err != nil {
		return 0, err
	}
	return port, nil
}

// ServerState says whether Koe may talk to the whisper-server it launched.
type ServerState int

const (
	ServerOwned        ServerState = iota // the child is running and is the only listener on its port
	ServerExited                          // the child is no longer running
	ServerNotListening                    // nothing listens on the port yet (still loading)
	ServerForeign                         // another process also listens on the port
)

func (s ServerState) String() string {
	switch s {
	case ServerOwned:
		return "owned"
	case ServerExited:
		return "exited"
	case ServerNotListening:
		return "not_listening"
	default:
		return "foreign"
	}
}

// CheckServer decides from the listener table whether the server on port is
// the child Koe started (pid). Every listener on the port counts, whatever
// its address (127.0.0.1, 0.0.0.0, IPv6 or another interface): all of them
// must be owned by the child.
func CheckServer(childRunning bool, table []Listener, port, pid int) ServerState {
	if !childRunning {
		return ServerExited
	}
	found := false
	for _, l := range table {
		if l.Port != port {
			continue
		}
		if l.PID != pid {
			return ServerForeign
		}
		found = true
	}
	if !found {
		return ServerNotListening
	}
	return ServerOwned
}

// ErrServerNotOwned: the server is not (or no longer) the child Koe started.
var ErrServerNotOwned = errors.New("whisper-server is not the one Koe started")

// CheckedWhisper is the whisper-server Koe started, checked before every
// request: Check returns an error when the child has exited or does not own
// its port any more, and then no audio is sent.
type CheckedWhisper struct {
	BaseURL string
	Check   func() error
}

func (w CheckedWhisper) Recognize(ctx context.Context, wav []byte, prompt string, fallback bool, audioCtx int) (string, error) {
	if w.Check != nil {
		if err := w.Check(); err != nil {
			return "", fmt.Errorf("%w: %v", ErrServerNotOwned, err)
		}
	}
	return Transcribe(ctx, w.BaseURL, wav, prompt, fallback, audioCtx)
}
