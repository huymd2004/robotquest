{-# LANGUAGE OverloadedStrings #-}

module Botland.Actions where

import Prelude hiding ((++))

import Botland.Helpers (uuid, l2b, b2l, (++))
import Botland.Types.Message (Fault(..))
import Botland.Types.Location (Field(..), Point(..), Size(..), Location(..), FieldInfo(..))
import Botland.Types.Unit (Spawn(..), UnitDescription(..))

import Database.Redis (runRedis, connect, defaultConnectInfo, ping, get, set, keys, Redis, Connection, incr, hset, Reply(..), hgetall, hdel, hsetnx, flushall)

import Data.Aeson (encode, decode)
import Data.ByteString.Char8 (pack, unpack, concat, ByteString(..))
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as L
import qualified Data.Text.Lazy as T
import Data.Maybe (fromMaybe, fromJust)



worldInfo :: FieldInfo
worldInfo = FieldInfo (Point 0 0) (Size 100 100)

sharedSpawn :: Point
sharedSpawn = Point 50 50

world :: Redis (Either Fault Field)
world = do
    reply <- hgetall "world"  
    case reply of
        Left r -> return $ Left (Fault "Could not get world")
        Right m -> return $ Right $ Field worldInfo (map toLocation m)

toLocation :: (ByteString, ByteString) -> Location
toLocation (ps, id) = Location p id
    where p = fromMaybe (Point 0 0) $ decode $ b2l ps

unitGetDescription :: ByteString -> Redis (Either Fault UnitDescription)
unitGetDescription uid = do
    reply <- get ("units:" ++ uid ++ ":description")
    case reply of
        Left _ -> return $ Left NotFound
        Right Nothing -> return $ Left NotFound
        Right (Just bs) -> do
            let ma = decode $ b2l bs :: Maybe UnitDescription
            case ma of
                Nothing -> return $ Left $ Fault "Could not parse description"
                Just a -> return $ Right a

-- spawning is relatively infrequent. 
-- it's ok if this is a little bit of an expensive operation?
-- or should I keep track of an index on every move?

-- when it starts: create the room?
-- set per room, the values are the locations?

unitSpawn :: UnitDescription -> Redis Spawn
unitSpawn d = do
    id <- uuid
    token <- uuid

    -- everyone starts at the same place. You don't exist until you move off of it.
    -- create a spawnAt 
    let p = sharedSpawn
    
    -- save the actor information, its token, and its position
    set ("units:" ++ id ++ ":description") (l2b $ encode d)
    set ("units:" ++ id ++ ":token") token
    set ("units:" ++ id ++ ":location") (l2b $ encode p)

    -- you don't exist until you step off the golden square
    --hset "world" (l2b $ encode p) id

    -- they need to know the info, the token, and the starting location, etc
    return $ Spawn id token p

unitMove :: ByteString -> Point -> Redis (Either Fault String)
unitMove uid p = do
    let lk = ("units:" ++ uid ++ ":location")
    ep <- get lk
    case ep of
        Left r -> return $ Left $ Fault (pack $ show r)
        Right Nothing -> return $ Left $ Fault "Could not find location"
        Right (Just bs) -> do

            -- possible error, except we put in ourselves
            let po = fromJust $ decode $ b2l bs

            if (not $ (neighboring p po && validPoint worldInfo p)) then 
                return $ Left $ Fault "Invalid move"
            else do

            res <- hsetnx "world" (l2b $ encode p) uid
            case res of 
                Right True -> do
                    set lk (l2b $ encode p)
                    hdel "world" [l2b $ encode po]
                    return $ Right "OK"
                _ -> return $ Left $ Fault "Space Occupied"

neighboring :: Point -> Point -> Bool
neighboring p1 p2 = withinOne (x p1) (x p2) && withinOne (y p1) (y p2)
    where withinOne a b = (a == b || a == (b-1) || a == (b+1))

validPoint :: FieldInfo -> Point -> Bool
validPoint f p = xmin < px && px < xmax && ymin < py && py < ymax && p /= sharedSpawn
    where px = x p
          py = y p
          xmin = x $ fieldStart f
          xmax = xmin + (width $ fieldSize f)
          ymin = y $ fieldStart f
          ymax = ymin + (height $ fieldSize f)

resetWorld :: Redis ()
resetWorld = do
    flushall
    return ()


authorized :: ByteString -> ByteString -> Redis Bool
authorized uid token = do
    r <- get ("units:" ++ uid ++ ":token")
    case r of
        Left r -> return False
        Right Nothing -> return False
        Right (Just bs) -> return (token == bs)

