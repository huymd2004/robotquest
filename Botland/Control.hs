{-# LANGUAGE OverloadedStrings, ExtendedDefaultRules #-}

module Botland.Control where

import Botland.Types

import Control.Monad.IO.Class (liftIO)

import Data.Maybe (isNothing, fromJust)
import Data.DateTime (DateTime, addSeconds, getCurrentTime)

import Database.MongoDB hiding (Field)

import Web.Scotty (ActionM(..))

-- randomId stuff 
import System.Random (randomIO)
import Numeric (showIntAtBase) 
import Data.Char (intToDigit)


-- SETUP ----------------------------------------------------------
ensureIndexes :: Action IO ()
ensureIndexes = do
    ensureIndex (Index "bots" ["x" =: 1, "y" =: 1] "xy" True True)

botOwner :: String -> String -> Action IO Bool
botOwner pid botId = do
    n <- count $ select ["playerId" =: pid, "_id" =: botId] "bots"
    return (n > 0)


-- DETAILS --------------------------------------------------------

botDetails :: String -> Action IO (Either Fault Bot)
botDetails id = do
    d <- findOne (select ["_id" =: id] "bots")

    if (isNothing d) then
        return $ Left NotFound
    else do

    return $ Right $ fromDoc (fromJust d)

topKillers :: Action IO [Bot]
topKillers = do
    c <- find (select ["kills" =: ["$gt" =: 0]] "bots") {sort = ["kills" =: -1], limit = 20}
    ds <- rest c
    return $ map fromDoc ds

topSurvivors :: Action IO [Bot]
topSurvivors = do
    c <- find (select [] "bots") {sort = ["created" =: 1], limit = 20}
    ds <- rest c
    return $ map fromDoc ds



-- PLAYER ---------------------------------------------------------

getPlayerByName :: String -> Action IO (Maybe Player)
getPlayerByName n = getPlayer ["name" =: n]

getPlayerById :: String -> Action IO (Maybe Player)
getPlayerById id = getPlayer ["_id" =: id]

{-getPlayer :: Field -> Action IO (Maybe Player)-}
getPlayer s = do
    md <- findOne (select s "players") {project = ["_id" =: 0]}
    case md of
        Nothing -> return Nothing
        Just d -> return $ Just $ fromDoc d
    
-- we provide a random id. It is your secret id from now on, and you use it to control your bots
createPlayer :: Player -> Action IO Id
createPlayer p = do
    id <- randomId
    let p' = p { playerId = id }
    save "players" (toDoc p')
    updateHeartbeat id
    return $ Id id


-- CREATION -------------------------------------------------------


createBot :: Game -> String -> Bot -> Action IO (Either Fault Id)
createBot g pid b = do
    id <- randomId
    time <- now
    mp <- getPlayerById pid

    if (isNothing mp) then
        return $ Left NotFound
    else do

    let p = fromJust mp
        pn = playerName p

    let ub = b { botId = id, botPlayerId = pid, player = pn, created = time }

    let v = validPosition g (x b) (y b)

    if (not v) then 
        return $ Left InvalidPosition 
    else do

    -- this insert will fail if the location is occupied
    insert_ "bots" (toDoc ub)

    return $ Right $ Id id 



-- GAME STATE -----------------------------------------------------

allBots :: Action IO [Bot]
allBots = do
    c <- find (select [] "bots")
    docs <- rest c
    return $ map fromDoc docs


allCommands :: Action IO [(String, BotCommand)]
allCommands = do
    cursor <- find (select [] "commands")
    docs <- rest cursor
    return $ map commandFromDoc docs


saveField :: Field -> Action IO ()
saveField f = undefined


-- ACTIONS --------------------------------------------------------

--setAction :: String -> BotAction -> Action IO Ok
--setAction id a = do
--    modify (select ["_id" =: id] "bots") ["$set" =: ["action" =: (show a)]]
--    return Ok 

performCommand :: BotCommand -> Game -> String -> String -> Action IO ()
performCommand c g pid id = do
    updateHeartbeat pid
    save "commands" (commandToDoc c id)

{-

moveAction :: Game -> String -> Direction -> Action IO (Either Fault Ok)
moveAction g id d = do

    -- I need to GET their current position
    doc <- findOne (select ["_id" =: id] "bots") {project = ["x" =: 1, "y" =: 1, "_id" =: 0]}

    if (isNothing doc) then
        return $ Left NotFound
    else do

    let bp = fromDoc (fromJust doc)
    let (Point x y) = move d bp

    let v = validPosition g x y
    if (not v) then 
        return $ Left InvalidPosition 
    else do 

    -- throws an error if someone is there
    modify (select ["_id" =: id] "bots") ["$set" =: ["x" =: x, "y" =: y]]

    return $ Right Ok

attackAction :: Game -> String -> Direction -> Action IO (Either Fault Ok)
attackAction g id d = do

    -- I need to GET their current position
    doc <- findOne (select ["_id" =: id] "bots") {project = ["x" =: 1, "y" =: 1, "_id" =: 0]}

    if (isNothing doc) then
        return $ Left NotFound
    else do

    let bp = fromDoc (fromJust doc)
    let (Point x y) = move d bp

    -- remove anybody there. Die sucka die
    -- see if anyone is there 
    targetDoc <- findOne (select ["x" =: x, "y" =: y] "bots") { project = ["_id" =: 1] }

    if (isNothing doc) then
        return $ Right Ok
    else do

    let tb = fromDoc (fromJust targetDoc) :: Bot

    -- nuke them!
    delete (select ["_id" =: botId tb] "bots")

    -- give the bot a kill
    modify (select ["_id" =: id] "bots") ["$inc" =: ["kills" =: 1]]

    return $ Right Ok
-}


-- CLEANUP ---------------------------------------------------------

-- save when the player last completed an action
updateHeartbeat :: String -> Action IO ()
updateHeartbeat pid = do
    time <- now
    modify (select ["_id" =: pid] "players") ["$set" =: ["heartbeat" =: time]]

cleanupPlayer :: String -> Action IO Ok
cleanupPlayer id = do
    liftIO $ putStrLn ("Cleaning Up " ++ id)
    delete (select ["playerId" =: id] "bots")
    delete (select ["_id" =: id] "players")
    return Ok

cleanupBot :: String -> Action IO Ok
cleanupBot botId = do
    delete (select ["_id" =: botId] "bots")
    return Ok

cleanupInactives :: Integer -> Action IO Ok
cleanupInactives delay = do

    time <- now
    let tenSecondsAgo = addSeconds (-delay) time

    c <- find (select ["heartbeat" =: ["$lt" =: tenSecondsAgo]] "players")
    docs <- rest c

    let ids = map playerId $ map fromDoc docs

    mapM_ cleanupPlayer ids 
    return Ok



-- THE WORLD -------------------------------------------------------

locations :: Action IO [Bot]
locations = do
    c <- find (select [] "bots") {project = ["playerId" =: 0]}
    bs <- rest c
    --return bs
    return $ map fromDoc bs 




-- HELPERS ----------------------------------------------------------

now :: Action IO DateTime
now = liftIO $ getCurrentTime

randomId :: Action IO String
randomId = do
    i <- liftIO $ randomIO
    return $ intToHex i

intToHex :: Int -> String
intToHex i = showIntAtBase 16 intToDigit (abs i) "" 

validPosition :: Game -> Int -> Int -> Bool
validPosition g x y = 0 <= x && x < (width g) && 0 <= y && y < (height g)
