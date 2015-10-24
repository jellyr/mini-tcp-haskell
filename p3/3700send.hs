module Main where
import TCP
import Control.Monad (unless, forever, when)
import Network.Socket
import Data.Time
import Data.Maybe
import Data.List.Split
import Data.List
import Control.Exception
import System.IO
import System.Environment
import Control.Concurrent
import System.Exit
import Debug.Trace

---- Client specific code

data CState = Finishing | Close | Established deriving (Show, Eq)

data Client = Client {
  cstate :: CState,
  unacked :: [(Seg, UTCTime)],
  unsent :: [Seg],
  toSend :: [Seg],
  lastRead :: Int, -- last seq number read from stdin
  lastAcked :: Int, -- last seq num acked. if delta between this and any unacked packets is high, just resend those packets (or decrease the timeout)
  timeoutM :: Float, -- modifier (multiplicative) (how long to wait before something times out), this may have to change if the delay is huge and things are timing out quickly. when something times out, increase this. when we get something back, decrease this (maybe)
  timeoutC :: Int -- num timeouts in a row
} deriving Show

---- Client Functions

isDoneSending :: Client -> Bool
isDoneSending c = finishing && emptyUnacked && emptyToSend
  where emptyUnacked = 0 == (length $ (unacked c))
        emptyToSend = 0 == (length $ (toSend c))
        finishing = (cstate c) == Finishing

stepClient :: Client -> UTCTime -> Maybe Seg -> Maybe String -> Client
stepClient c now fromServer fromStdin = (sendUnsent (retry (addToUnsent (recAck c fromServer) fromStdin) now) now)

-- updateTimeoutM :: Client -> Client
-- updateTimeoutM c
--   | m == 1 &&  = 1
--   |
--       where m = (timeoutM c)

isClosed :: Client -> Bool
isClosed c = (cstate c) == Close

isExpired :: Float -> UTCTime -> (Seg, UTCTime) -> Bool
isExpired m now (_, old) = (segmentExpiryTime * m) < (realToFrac (abs $ diffUTCTime old now))

recAck :: Client -> Maybe Seg -> Client
recAck c Nothing = c
recAck c@(Client Finishing _ _ _ _ _ _ _) (Just (Seg Fin _ _ _)) = c { cstate = Close }
recAck c (Just (Seg _ num _ _)) = c { unacked = newUnacked,
                                      lastAcked = (max (lastAcked c) num),
                                      --timeoutM = newTimeout,
                                      timeoutC = 0 }
    where newUnacked = filter (\(s,t) -> (seqNum s) /= num) (unacked c)
          --newTimeout = newTimeoutM Decrease (timeoutM c)

sendUnsent :: Client -> UTCTime -> Client
sendUnsent c now = c { unsent = ((unsent c) \\ sendMe),
                       unacked = (unacked c) ++ withTime,
                       toSend = (toSend c) ++ sendMe }
    where toTake = length $ (unsent c) -- length (toSend c)
          sendMe = take toTake (unsent c) -- this may change later depending on cwnd decisions
          withTime = map (\x -> (x,now)) sendMe

-- data Modify = Increase | Decrease

-- newTimeoutM :: Float -> Float
-- -- newTimeoutM _ x = x
-- newTimeoutM Increase x = x + 1.0
-- newTimeoutM Decrease 1 = 1
-- newTimeoutM Decrease x = x - 1.0

  -- unacked is sorted from
retry :: Client -> UTCTime -> Client
retry client@(Client _ uacked _ tosend _ _ timeM _) now =
    client { unacked = update,
             toSend = (tosend ++ noTime),
             timeoutM = newTimeout}
             --timeoutC = timeC + (length expired)}
    where expired = filter (isExpired timeM now) uacked
          update = map (\segt@(s,_) -> if elem segt expired then (s,now) else segt) uacked
          noTime = map fst expired
          newTimeout = if 3 <= (length expired) then timeM * 1.5 else timeM

addToUnsent :: Client -> Maybe String -> Client
addToUnsent c Nothing = c
addToUnsent c (Just s)
  | s == "#EOF#" = c { cstate = Finishing }
  | otherwise = c { unsent = (unsent c) ++ [newSeg], lastRead = newlastread }
      where newlastread = (lastRead c) + 1
            newSeg = hashSeg $ Seg Data newlastread s "NOHASHYET"

-- Helpers

sendServer :: Socket -> Int -> [Seg] -> IO ()
sendServer socket groups segs =
  do
    connected <- isWritable socket
    when connected $ do
    -- splitting should occur
      let sendme = combine groups $ map show segs
      putStrLn $ show sendme
      mapM (send socket) $ sendme
      timestamp "[send data] todo"

timestamp :: String -> IO ()
timestamp s =
  do
    t <- getCurrentTime
    hPutStrLn stderr $ "<" ++ (show t) ++ "> " ++ s

getSocket :: String -> String -> IO Socket
getSocket host port =
  do
    (serveraddr:_) <- getAddrInfo Nothing (Just host) (Just port)
    s <- socket (addrFamily serveraddr) Datagram defaultProtocol
    connect s (addrAddress serveraddr)
    return s

-- Forked IO functions, continuously running

receiveFromServer :: Socket -> Chan String -> IO ()
receiveFromServer s fromServer = do
  forever $ do
    connected <- isReadable s
    unless connected $ exitSuccess
    message <- recv s 1024
    timestamp "[recv ack] offset goes here"
    writeChan fromServer message

clientLoop :: Client -> Socket -> Chan String -> Chan String -> IO ()
clientLoop c s fromServer fromStdin =
  do
    serverMessage <- tryGet fromServer
    stdinMessage <- tryGet fromStdin
    now <- getCurrentTime
    let nextClient = stepClient c now (parseSeg serverMessage) stdinMessage
    sendServer s 5 $ toSend nextClient
    let emptiedToSend = nextClient { toSend = [] }
    when (isDoneSending emptiedToSend) $ do
      let fin = hashSeg $ Seg Fin (-1) "" ""
      finishUp (emptiedToSend { unsent = [fin] }) s fromServer
      exitSuccess
    --putStrLn $ show emptiedToSend
    --when (isClosed emptiedToSend && 0 == (length $ unacked emptiedToSend) $ exitSuccess
    clientLoop emptiedToSend s fromServer fromStdin

finishUp :: Client -> Socket -> Chan String -> IO ()
finishUp c s fromServer =
  do
    serverMessage <- tryGet fromServer
    now <- getCurrentTime
    let nextClient = stepClient c now (parseSeg serverMessage) Nothing
    unless ((cstate nextClient) == Close) $ do
      sendServer s 5 $ toSend nextClient
      let emptiedToSend = nextClient { toSend = [] }
      finishUp emptiedToSend s fromServer

readStdin :: Socket -> Chan String -> IO ()
readStdin s fromStdin =
  do
    lines <- getContents
    mapM (writeChan fromStdin) $ chunksOf 1000 lines
    writeChan fromStdin "#EOF#"

    -- line <- getLine
    -- eof <- isEOF
    -- if eof then do
    --   writeChan fromStdin line
    --   writeChan fromStdin "#EOF#"
    --   else do
    --     -- let lines = chunksOf 2 (line ++ "\n")
    --     writeChan fromStdin (line ++ "\n")
    --     -- let pieces = chunksOf mss line
    --     -- mapM (writeChan fromStdin) pieces
    --     readStdin s fromStdin

---- Initialization

-- Initial run function. Sends syn (for now),
-- initiates channels, starts reading/writing loops, starts client loop

startAndSyn :: Socket -> IO ()
startAndSyn s =
  do
    fromServer <- newChan
    fromStdin <- newChan
    -- toServer <- newChan
    receiving <- forkIO $ receiveFromServer s fromServer
    -- sending <- forkIO $ sendToServer s toServer
    reading <- forkIO $ readStdin s fromStdin
    let client = Client Established [] [] [] 0 0 1.0 0
    -- send s init
    -- timestamp $ "[send syn] "
    clientLoop client s fromServer fromStdin

-- Build the socket, run startAndSyn

main :: IO ()
main = do
    args <- getArgs
    let
      splitMe = splitOn ":" (args!!0)
      host = (splitMe!!0)
      port = (splitMe!!1)
    withSocketsDo $ bracket (getSocket host port) sClose startAndSyn
