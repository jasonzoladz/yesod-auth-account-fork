{- Copyright (c) 2014 John Lenz

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
-}

{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -fno-warn-orphans #-} -- Only orphan instance is RenderMessage AccountMessage

-- | An auth plugin for accounts. Each account consists of a username, email, and password.
--
-- This module is designed so that you can use the default pages for login, account
-- creation, change password, etc.  But the module also exports some forms which you
-- can embed into your own pages, customizing the account process.  The minimal requirements
-- to use this module are:
--
-- * If you are not using persistent or just want more control over the user data, you can use
--   any datatype for user information and make it an instance of 'UserCredentials'.  You must
--   also create an instance of 'AccountDB'.
--
-- * You may use a user datatype created by persistent, in which case you can make the datatype
--   an instance of 'PersistUserCredentials' instead of 'UserCredentials'.  In this case,
--   'AccountPersistDB' from this module already implements the 'AccountDB' interface for you.
--   Currently the persistent option requires both an unique username and email.
--
-- * Make your master site an instance of 'AccountSendEmail'.  By default, this class
--   just logs a message so during development this class requires no implementation.
--
-- * Make your master site and database an instance of 'YesodAuthAccount'.  There is only
--   one required function which must be implemented ('runAccountDB') although there
--   are several functions you can override in this class to customize the behavior of this
--   module.
--
-- * Include 'accountPlugin' in the list of plugins in your instance of 'YesodAuth'.
module Yesod.Auth.Account(
    -- * Plugin
      Username
    , newAccountR
    , resetPasswordR
    , accountPlugin

    -- * Login
    , LoginData(..)
    , loginForm
    , loginFormPostTargetR
    , loginWidget

    -- * New Account
    -- $newaccount
    , verifyR
    , NewAccountData(..)
    , newAccountForm
    , newAccountWidget
    , createNewAccount
    , resendVerifyEmailForm
    , resendVerifyR
    , resendVerifyEmailWidget

    -- * Password Reset
    -- $passwordreset
    , newPasswordR
    , newPasswordLoggedR
    , resetPasswordForm
    , resetPasswordWidget
    , NewPasswordData(..)
    , newPasswordForm
    , setPasswordR
    , newPasswordWidget

    -- * Database and Email
    , UserCredentials(..)
    , PersistUserCredentials(..)
    , AccountDB(..)
    , AccountSendEmail(..)

    -- * Persistent
    , AccountPersistDB
    , runAccountPersistDB

    -- * Customization
    , YesodAuthAccount(..)

    -- * Helpers
    , hashPassword
    , verifyPassword
    , newVerifyKey
) where

import Control.Applicative
import Control.Monad.Reader hiding (lift)
import Data.Char (isAlphaNum)
import Data.Maybe
import Data.Monoid ((<>))
import Data.Proxy (Proxy(..))
import Network.HTTP.Types (unauthorized401)
import System.IO.Unsafe (unsafePerformIO)
import qualified Crypto.PasswordStore as PS
import qualified Crypto.Nonce as Nonce
import qualified Data.Aeson as A
import qualified Data.ByteString as B
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Database.Persist as P
import Text.Email.Validate

import Yesod.Core
import Yesod.Form
import Yesod.Auth
import Yesod.Persist hiding (get, replace, insertKey, Entity, entityVal)
import qualified Yesod.Auth.Message as Msg

import Yesod.Auth.Account.Message

-- | Each user is uniquely identified by a username.
type Username = T.Text
-- | And email (for now just in the Persistent backend).
type Email = T.Text

-- | The account authentication plugin.  Here is a complete example using persistent 2.1
-- and yesod 1.4.
--
-- >{-# LANGUAGE QuasiQuotes, TypeFamilies, GeneralizedNewtypeDeriving #-}
-- >{-# LANGUAGE FlexibleContexts, FlexibleInstances, TemplateHaskell, OverloadedStrings #-}
-- >{-# LANGUAGE GADTs, MultiParamTypeClasses, TypeSynonymInstances #-}
-- >
-- >import Data.Text (Text)
-- >import Data.ByteString (ByteString)
-- >import Database.Persist.Sqlite
-- >import Control.Monad.Logger (runStderrLoggingT)
-- >import Yesod
-- >import Yesod.Auth
-- >import Yesod.Auth.Account
-- >
-- >share [mkPersist sqlSettings, mkMigrate "migrateAll"] [persistUpperCase|
-- >User
-- >    username Text
-- >    UniqueUsername username
-- >    password ByteString
-- >    emailAddress Text
-- >    UniqueEmailAddress emailAddress
-- >    verified Bool
-- >    verifyKey Text
-- >    resetPasswordKey Text
-- >    deriving Show
-- >|]
-- >
-- >instance PersistUserCredentials User where
-- >    userUsernameF = UserUsername
-- >    userPasswordHashF = UserPassword
-- >    userEmailF = UserEmailAddress
-- >    userEmailVerifiedF = UserVerified
-- >    userEmailVerifyKeyF = UserVerifyKey
-- >    userResetPwdKeyF = UserResetPasswordKey
-- >    uniqueUsername = UniqueUsername
-- >    uniqueEmailaddress = UniqueEmailAddress
-- >
-- >    userCreate name email key pwd = User name pwd email False key ""
-- >
-- >data MyApp = MyApp ConnectionPool
-- >
-- >mkYesod "MyApp" [parseRoutes|
-- >/ HomeR GET
-- >/auth AuthR Auth getAuth
-- >|]
-- >
-- >instance Yesod MyApp
-- >
-- >instance RenderMessage MyApp FormMessage where
-- >    renderMessage _ _ = defaultFormMessage
-- >
-- >instance YesodPersist MyApp where
-- >    type YesodPersistBackend MyApp = SqlBackend
-- >    runDB action = do
-- >        MyApp pool <- getYesod
-- >        runSqlPool action pool
-- >
-- >instance YesodAuth MyApp where
-- >    type AuthId MyApp = Username
-- >    getAuthId = return . Just . credsIdent
-- >    loginDest _ = HomeR
-- >    logoutDest _ = HomeR
-- >    authPlugins _ = [accountPlugin]
-- >    authHttpManager _ = error "No manager needed"
-- >    onLogin = return ()
-- >    maybeAuthId = lookupSession credsKey
-- >
-- >instance AccountSendEmail MyApp
-- >
-- >instance YesodAuthAccount (AccountPersistDB MyApp User) MyApp where
-- >    runAccountDB = runAccountPersistDB
-- >    getTextId _ = return
-- >
-- >getHomeR :: Handler Html
-- >getHomeR = do
-- >    maid <- maybeAuthId
-- >    case maid of
-- >        Nothing -> defaultLayout $ [whamlet|
-- ><p>Please visit the <a href="@{AuthR LoginR}">Login page</a>
-- >|]
-- >        Just u -> defaultLayout $ [whamlet|
-- ><p>You are logged in as #{u}
-- ><p><a href="@{AuthR LogoutR}">Logout</a>
-- >|]
-- >
-- >main :: IO ()
-- >main = runStderrLoggingT $ withSqlitePool "test.db3" 10 $ \pool -> do
-- >    runSqlPool (runMigration migrateAll) pool
-- >    liftIO $ warp 3000 $ MyApp pool
--
accountPlugin :: YesodAuthAccount db master => AuthPlugin master
accountPlugin = AuthPlugin "account" dispatch loginWidget
    where dispatch "POST" ["login"] = postLoginR >>= sendResponse
          dispatch "GET"  ["newaccount"] = getNewAccountR >>= sendResponse
          dispatch "POST" ["newaccount"] = postNewAccountR >>= sendResponse
          dispatch "GET"  ["resetpassword"] = getResetPasswordR >>= sendResponse
          dispatch "POST" ["resetpassword"] = postResetPasswordR >>= sendResponse
          dispatch "GET"  ["verify", u, k] = getVerifyR u k >>= sendResponse
          dispatch "GET"  ["newpassword", u, k] = getNewPasswordR u k >>= sendResponse
          dispatch "GET"  ["newpasswordlgd"] = getNewPasswordLoggedR >>= sendResponse
          dispatch "POST" ["setpassword"] = postSetPasswordR >>= sendResponse
          dispatch "POST" ["resendverifyemail"] = postResendVerifyEmailR >>= sendResponse
          dispatch _ _ = notFound

-- | The POST target for the 'loginForm'.
loginFormPostTargetR :: AuthRoute
loginFormPostTargetR = PluginR "account" ["login"]

-- | Route for the default new account page.
--
-- See the New Account section below for customizing the new account process.
newAccountR :: AuthRoute
newAccountR = PluginR "account" ["newaccount"]

-- | Route for the reset password page.
--
-- This page allows the user to reset their password by requesting an email with a
-- reset URL be sent to them.  See the Password Reset section below for customization.
resetPasswordR :: AuthRoute
resetPasswordR = PluginR "account" ["resetpassword"]

-- | The URL sent in an email for email verification
verifyR :: Username
        -> T.Text -- ^ The verification key
        -> AuthRoute
verifyR u k = PluginR "account" ["verify", u, k]

-- | The POST target for resending a verification email
resendVerifyR :: AuthRoute
resendVerifyR = PluginR "account" ["resendverifyemail"]

-- | The URL sent in an email when the user requests to reset their password
newPasswordR :: Username
             -> T.Text -- ^ The verification key
             -> AuthRoute
newPasswordR u k = PluginR "account" ["newpassword", u, k]

-- | Choose a new password while logged in
newPasswordLoggedR :: AuthRoute
newPasswordLoggedR = PluginR "account" ["newpasswordlgd"]

-- | The POST target for reseting the password
setPasswordR :: AuthRoute
setPasswordR = PluginR "account" ["setpassword"]


---------------------------------------------------------------------------------------------------


-- | The data collected in the login form.
data LoginData = LoginData {
      loginUsername :: T.Text
    , loginPassword :: T.Text
} deriving Show

-- | The login form.
--
-- You can embed this form into your own pages if you want a custom rendering of this
-- form or to include a login form on your own pages. The form submission should be
-- posted to 'loginFormPostTargetR'.
loginForm :: (MonadHandler m, YesodAuthAccount db master, HandlerSite m ~ master)
          => AForm m LoginData
loginForm = LoginData <$> areq (checkM checkValidLogin textField) userSettings Nothing
                      <*> areq passwordField pwdSettings Nothing
    where userSettings = FieldSettings (SomeMessage MsgLoginName) Nothing (Just "username") Nothing []
          pwdSettings  = FieldSettings (SomeMessage Msg.Password) Nothing (Just "password") Nothing []

-- | A default rendering of 'loginForm' using renderDivs.
--
-- This is the widget used in the default implementation of 'loginHandler'.
-- The widget also includes links to the new account and reset password pages.
loginWidget :: YesodAuthAccount db master => (Route Auth -> Route master) -> WidgetT master IO ()
loginWidget tm = do
    ((_,widget), enctype) <- liftHandlerT $ runFormPostNoToken $ renderDivs loginForm
    [whamlet|
<div .loginDiv>
    <form method=post enctype=#{enctype} action=@{tm loginFormPostTargetR}>
        ^{widget}
        <input type=submit value=_{Msg.LoginTitle}>
    <p>
        <a href="@{tm newAccountR}">_{Msg.RegisterLong}
        <a href="@{tm resetPasswordR}">_{MsgForgotPassword}
|]

postLoginR :: YesodAuthAccount db master => HandlerT Auth (HandlerT master IO) TypedContent
postLoginR = do
    ((result, _), _) <- lift $ runFormPostNoToken $ renderDivs loginForm
    muser <- case result of
                FormMissing -> invalidArgs ["Form is missing"]
                FormFailure _ -> return $ Left Msg.InvalidLogin
                FormSuccess (LoginData uname pwd) -> do
                    mu <- lift $ runAccountDB $ loadUser uname
                    case mu of
                        Nothing -> return $ Left Msg.InvalidUsernamePass
                        Just u -> return $
                            if verifyPassword pwd (userPasswordHash u)
                                then Right u
                                else Left Msg.InvalidUsernamePass

    case muser of
        Left err -> loginErrorMessageI LoginR err
        Right u -> if userEmailVerified u
                        then lift $ setCredsRedirect $ Creds "account" (username u) []
                        else unregisteredLogin u

---------------------------------------------------------------------------------------------------

-- $newaccount
-- The new account process works as follows.
--
-- * A GET to 'newAccountR' displays a form requesting account information
--   from the user.  The specific page to display can be customized by implementing
--   'getNewAccountR'.  By default, this is the content of 'newAccountForm' which
--   consists of an username, email, and a password.  The target for the form is a
--   POST to 'newAccountR'.
--
-- * A POST to 'newAccountR' handles the account creation.  By default, 'postNewAccountR'
--   processes 'newAccountForm' and then calls 'createNewAccount' to create the account
--   in the database, generate a random key, and send an email with the verification key.
--   If you have modified 'getNewAccountR' to add additional fields to the new account
--   form (for example CAPTCHA or other account info), you can override 'postNewAccountR'
--   to handle the form.  You should still call 'createNewAccount' from your own processing
--   function.
--
-- * The verification email includes a URL to 'verifyR'.  A GET to 'verifyR' checks
--   if the key matches, and if so updates the database and uses 'setCreds' to log the
--   user in and redirects to 'loginDest'.  If an error occurs, a message is set and the
--   user is redirected to 'LoginR'.
--
-- * A POST to 'resendVerifyR' of 'resendVerifyEmailForm' will generate a new verification key
--   and resend the email.  By default, 'unregisteredLogin' displays the form for resending
--   the email.

-- | The data collected in the new account form.
data NewAccountData = NewAccountData {
      newAccountUsername :: Username
    , newAccountEmail :: T.Text
    , newAccountPassword1 :: T.Text
    , newAccountPassword2 :: T.Text
} deriving Show

-- | The new account form.
--
-- You can embed this form into your own pages or into 'getNewAccountR'.  The form
-- submission should be posted to 'newAccountR'.  Alternatively, you could embed this
-- form into a larger form where you prompt for more information during account
-- creation.  In this case, the NewAccountData should be passed to 'createNewAccount'
-- from inside 'postNewAccountR'.
newAccountForm :: (YesodAuthAccount db master
                  , MonadHandler m
                  , HandlerSite m ~ master
                  ) => AForm m NewAccountData
newAccountForm = NewAccountData <$> areq (checkM checkValidUsername textField) userSettings Nothing
                                <*> areq (checkM checkValidEmail emailField) emailSettings Nothing
                                <*> areq passwordField pwdSettings1 Nothing
                                <*> areq passwordField pwdSettings2 Nothing
    where userSettings  = FieldSettings (SomeMessage MsgUsername) Nothing Nothing Nothing []
          emailSettings = FieldSettings (SomeMessage Msg.Email) Nothing Nothing Nothing []
          pwdSettings1  = FieldSettings (SomeMessage Msg.Password) Nothing Nothing Nothing []
          pwdSettings2  = FieldSettings (SomeMessage Msg.ConfirmPass) Nothing Nothing Nothing []

-- | A default rendering of the 'newAccountForm' using renderDivs.
newAccountWidget :: YesodAuthAccount db master => (Route Auth -> Route master) -> WidgetT master IO ()
newAccountWidget tm = do
    ((_,widget), enctype) <- liftHandlerT $ runFormPost $ renderDivs newAccountForm
    [whamlet|
<div .newaccountDiv>
    <form method=post enctype=#{enctype} action=@{tm newAccountR}>
        ^{widget}
        <input type=submit value=_{Msg.Register}>
|]

-- | An action to create a new account.
--
-- You can use this action inside your own implementation of 'postNewAccountR' if you
-- add additional fields to the new account creation.  This action assumes the user has
-- not yet been created in the database and will create the user, so this action should
-- be run first in your handler.  Note that this action does not check if the passwords
-- are equal. If an error occurs (username exists, etc.) this will set a message and
-- redirect to 'newAccountR'.
createNewAccount :: YesodAuthAccount db master => NewAccountData -> (Route Auth -> Route master) -> HandlerT master IO (UserAccount db)
createNewAccount (NewAccountData u email pwd _) tm = do
    muser <- runAccountDB $ loadUser u
    case muser of
        Just _ -> do setMessageI $ MsgUsernameExists u
                     redirect $ tm newAccountR
        Nothing -> return ()

    muser' <- runAccountDB $ loadUser email
    case muser' of
        Just _ -> do setMessageI $ MsgEmailExists email
                     redirect $ tm resetPasswordR
        Nothing -> return ()
    key <- newVerifyKey
    hashed <- hashPassword pwd

    mnew <- runAccountDB $ addNewUser u email key hashed
    new <- case mnew of
        Left err -> do setMessage $ toHtml err
                       redirect $ tm newAccountR
        Right x -> return x

    render <- getUrlRender
    sendVerifyEmail u email $ render $ tm $ verifyR u key
    setMessageI $ Msg.ConfirmationEmailSent email
    return new

getVerifyR :: YesodAuthAccount db master => Username -> T.Text -> HandlerT Auth (HandlerT master IO) ()
getVerifyR uname k = do
    muser <- lift $ runAccountDB $ loadUser uname
    case muser of
        Nothing -> do lift $ setMessageI Msg.InvalidKey
                      redirect LoginR
        Just user -> do when (    userEmailVerifyKey user == ""
                               || userEmailVerifyKey user /= k
                               || userEmailVerified user
                             ) $ do
                            lift $ setMessageI Msg.InvalidKey
                            redirect LoginR
                        lift $ runAccountDB $ verifyAccount user
                        lift $ setMessageI MsgEmailVerified
                        lift $ setCreds True $ Creds "account" uname []

-- | A form to allow the user to request the email validation be resent.
--
-- Intended for use in 'unregisteredLogin'.  The result should be posted to
-- 'resendVerifyR'.
resendVerifyEmailForm :: (RenderMessage master FormMessage
                         , MonadHandler m
                         , HandlerSite m ~ master
                         ) => Username -> AForm m Username
resendVerifyEmailForm u = areq hiddenField "" $ Just u

-- | A default rendering of 'resendVerifyEmailForm'
resendVerifyEmailWidget :: YesodAuthAccount db master => Username -> (Route Auth -> Route master) -> WidgetT master IO ()
resendVerifyEmailWidget u tm = do
    ((_,widget), enctype) <- liftHandlerT $ runFormPost $ renderDivs $ resendVerifyEmailForm u
    [whamlet|
<div .resendVerifyEmailDiv>
    <form method=post enctype=#{enctype} action=@{tm resendVerifyR}>
        ^{widget}
        <input type=submit value=_{MsgResendVerifyEmail}>
|]

postResendVerifyEmailR :: YesodAuthAccount db master => HandlerT Auth (HandlerT master IO) ()
postResendVerifyEmailR = do
    ((result, _), _) <- lift $ runFormPost $ renderDivs $ resendVerifyEmailForm ""
    muser <- case result of
                FormMissing -> invalidArgs ["Form is missing"]
                FormFailure msg -> invalidArgs msg
                FormSuccess uname -> lift $ runAccountDB $ loadUser uname

    case muser of
        -- The username is a hidden field so it should be correct.  No need to set a message or redirect.
        Nothing -> invalidArgs ["Invalid username"]
        Just u  -> do
            key <- newVerifyKey
            lift $ runAccountDB $ setVerifyKey u key
            render <- getUrlRender
            lift $ sendVerifyEmail (username u) (userEmail u) $ render $ verifyR (username u) key
            lift $ setMessageI $ Msg.ConfirmationEmailSent (userEmail u)
            redirect LoginR

---------------------------------------------------------------------------------------------------

-- $passwordreset
-- This plugin implements password reset by sending the user an email containing a URL.  When
-- the user visits this URL, they are prompted for a new password.  This works as follows:
--
-- * A GET to 'resetPasswordR' displays a form prompting for username, which when submitted sends
--   a post to 'resetPasswordR'.   You can customize this page by overriding 'getResetPasswordR'
--   or by embedding 'resetPasswordForm' into your own page and not linking your users to this URL.
--
-- * A POST to 'resetPasswordR' of 'resetPasswordForm' creates a new key, stores it in the database,
--   and sends an email.  It then sets a message and redirects to the login page.  You can redirect
--   somewhere else (or carry out other actions) at the end of 'sendNewPasswordEmail'.  The URL sent
--   in the email is 'setPasswordR'.
--
-- * A GET to 'newPasswordR' checks if the key in the URL is correct and if so displays a form
--   where the user can set a new password.  The key is set as a hidden field in this form.  You
--   can customize the look of this page by overriding 'setPasswordHandler'.
--
-- * A POST to 'setPasswordR' of 'resetPasswordForm' checks if the key is correct and if so,
--   resets the password.  It then calls 'setCreds' to successfully log in and so redirects to
--   'loginDest'.
--
-- * You can set 'allowPasswordReset' to False, in which case the relevant routes in this
--   plugin return 404.  You can then implement password reset yourself.

-- | A form for the user to request that an email be sent to them to allow them to reset
-- their password.  This form contains a field for the username (plus the CSRF token).
-- The form should be posted to 'resetPasswordR'.
resetPasswordForm :: (YesodAuthAccount db master
                     , MonadHandler m
                     , HandlerSite m ~ master
                     ) => AForm m Username
resetPasswordForm = areq textField userSettings Nothing
    where userSettings = FieldSettings (SomeMessage MsgLoginName) Nothing (Just "username") Nothing []

-- | A default rendering of 'resetPasswordForm'.
resetPasswordWidget :: YesodAuthAccount db master
                    => (Route Auth -> Route master) -> WidgetT master IO ()
resetPasswordWidget tm = do
    ((_,widget), enctype) <- liftHandlerT $ runFormPost $ renderDivs resetPasswordForm
    [whamlet|
<div .resetPasswordDiv>
    <form method=post enctype=#{enctype} action=@{tm resetPasswordR}>
        ^{widget}
        <input type=submit value=_{Msg.SendPasswordResetEmail}>
|]

postResetPasswordR :: YesodAuthAccount db master => HandlerT Auth (HandlerT master IO) Html
postResetPasswordR = do
    allow <- allowPasswordReset <$> lift getYesod
    unless allow notFound
    ((result, _), _) <- lift $ runFormPost $ renderDivs resetPasswordForm
    mdata <- case result of
                FormMissing -> invalidArgs ["Form is missing"]
                FormFailure msg -> return $ Left msg
                FormSuccess uname -> Right <$> lift (runAccountDB (loadUser uname))

    case mdata of
        Left errs -> do
            setMessage $ toHtml $ T.concat errs
            redirect LoginR

        Right Nothing -> do
            lift $ setMessageI MsgInvalidUsername
            redirect resetPasswordR

        Right (Just u) -> do key <- newVerifyKey
                             lift $ runAccountDB $ setNewPasswordKey u key
                             render <- getUrlRender
                             lift $ sendNewPasswordEmail (username u) (userEmail u) $ render $ newPasswordR (username u) key
                             -- Don't display the email in the message since anybody can request the resend.
                             lift $ setMessageI MsgResetPwdEmailSent
                             redirect LoginR

-- | The data for setting a new password.
data NewPasswordData = NewPasswordData {
      newPasswordUser :: Username
    , newPasswordKey  :: Maybe T.Text -- ^ Holds the verification key sent by email
    , newPasswordOld  :: Maybe T.Text -- ^ Alternatively, will hold the current password for creds validation
    , newPasswordPwd1 :: T.Text
    , newPasswordPwd2 :: T.Text
} deriving Show

-- | The form for setting a new password. It contains hidden fields for the username and key,
-- and optionally a field for the user to input its current password, besides the new passwords.
-- This form should be posted to 'setPasswordR'.
newPasswordForm :: (YesodAuthAccount db master, MonadHandler m, HandlerSite m ~ master)
                => Username
                -> Maybe T.Text -- ^ key
                -> AForm m NewPasswordData
newPasswordForm u k = NewPasswordData <$> areq hiddenField "" (Just u)
                                      <*> aopt hiddenField "" (Just k)
                                      -- The presence of the optional key will dictate if we show the
                                      -- old password field
                                      <*> (if isNothing k then aopt passwordField newPassword  Nothing
                                                          else aopt hiddenField "" Nothing)
                                      <*> areq passwordField pwdSettings1 Nothing
                                      <*> areq passwordField pwdSettings2 Nothing
    where pwdSettings1 = FieldSettings (SomeMessage Msg.NewPass) Nothing Nothing Nothing []
          pwdSettings2 = FieldSettings (SomeMessage Msg.ConfirmPass) Nothing Nothing Nothing []
          newPassword  = FieldSettings (SomeMessage MsgCurrentPassword) Nothing Nothing Nothing []

-- | A default rendering of 'newPasswordForm'.
newPasswordWidget :: YesodAuthAccount db master
    => Bool            -- ^ Has verification key (True) or should it present the actual password field(False)?
    ->UserAccount db
    -> (Route Auth -> Route master)
    -> WidgetT master IO ()
newPasswordWidget withKey user tm = do
    let key = if withKey
                then Just $ userResetPwdKey user
                else Nothing
    ((_,widget), enctype) <- liftHandlerT $ runFormPost $ renderDivs (newPasswordForm (username user) key)
    [whamlet|
<div .newpassDiv>
    <p>_{Msg.SetPass}
    <form method=post enctype=#{enctype} action=@{tm setPasswordR}>
        ^{widget}
        <input type=submit value=_{Msg.SetPassTitle}>
|]

getNewPasswordR :: YesodAuthAccount db master => Username -> T.Text -> HandlerT Auth (HandlerT master IO) Html
getNewPasswordR uname k = do
    allow <- allowPasswordReset <$> lift getYesod
    unless allow notFound
    muser <- lift $ runAccountDB $ loadUser uname
    case muser of
        Just user | userResetPwdKey user /= "" && userResetPwdKey user == k ->
            setPasswordHandler True user

        _ -> do lift $ setMessageI Msg.InvalidKey
                redirect LoginR

-- | Configure a new password while logged in
getNewPasswordLoggedR :: YesodAuthAccount db master => HandlerT Auth (HandlerT master IO) Html
getNewPasswordLoggedR = do
    allow <- allowPasswordReset <$> lift getYesod
    unless allow notFound
    uname <- loggedInUser
    muser <- lift $ runAccountDB $ loadUser uname
    case muser of
        Just user -> runIfLogged (setPasswordHandler False user)
        _ -> notAuthenticated

postSetPasswordR :: YesodAuthAccount db master => HandlerT Auth (HandlerT master IO) ()
postSetPasswordR = do
    allow <- allowPasswordReset <$> lift getYesod
    unless allow notFound
    ((result,_), _) <- lift $ runFormPost $ renderDivs (newPasswordForm "" Nothing)
    mnew <- case result of
                FormMissing -> invalidArgs ["Form is missing"]
                FormFailure msg -> return $ Left msg
                FormSuccess d | newPasswordPwd1 d == newPasswordPwd2 d
                                && (   isJust (newPasswordOld d)
                                    || isJust (newPasswordKey d)) -> return $ Right d
                FormSuccess d -> do lift $ setMessageI Msg.PassMismatch
                                    handleNullFields
                      where
                        handleNullFields | null (catMaybes [newPasswordOld d, newPasswordKey d]) =
                                              invalidArgs ["Form is incorrect"]
                                         | isNothing (newPasswordKey d) =  redirect $ newPasswordLoggedR
                                         | otherwise =  redirect $ newPasswordR (newPasswordUser d)
                                                                   (fromMaybe "" (newPasswordKey d))

    case mnew of
        Left errs -> do
            setMessage $ toHtml $ T.concat errs
            redirect LoginR

        Right d -> do muser <- lift $ runAccountDB $ loadUser (newPasswordUser d)
                      case muser of
                        -- username is a hidden field so it should be correct.  No need to set a message and redirect.
                        Nothing -> permissionDenied "Invalid username"
                        Just user -> do
                              case newPasswordOld d of
                                -- If no old password, we'll assume this is a key validated operation
                                Nothing -> do
                                  -- the key is a hidden field, no need to set a message and redirect.
                                  when (userResetPwdKey user == "") $ permissionDenied "Invalid key"
                                  when (maybe True ((/=) (userResetPwdKey user)) (newPasswordKey d))
                                      $ permissionDenied "Invalid key"
                                Just oldPassword ->
                                  unless (verifyPassword oldPassword (userPasswordHash user))
                                         (lift (setMessageI  MsgInvalidPassword) >> redirect newPasswordLoggedR )

                              hashed <- hashPassword (newPasswordPwd1 d)
                              lift $ runAccountDB $ setNewPassword user hashed
                              lift $ setMessageI Msg.PassUpdated
                              lift $ setCreds True $ Creds "account" (newPasswordUser d) []

---------------------------------------------------------------------------------------------------

-- | Interface for the data type which stores the user info when not using persistent.
--
--   You must make a data type that is either an instance of this class or of
--   'PersistUserCredentials', depending on if you are using persistent or not.
--
--   Users are uniquely identified by their username or their email, and for each user we must
--   store the email, the verify status, a hashed user password, and a reset password key.
--   The format for the hashed password is the format from "Crypto.PasswordStore".
--   If the email has been verified and no password reset is in progress, the relevent keys
--   should be the empty string.
class UserCredentials u where
    username           :: u -> Username
    userPasswordHash   :: u -> B.ByteString -- ^ see "Crypto.PasswordStore" for the format
    userEmail          :: u -> T.Text
    userEmailVerified  :: u -> Bool       -- ^ the status of the user's email verification
    userEmailVerifyKey :: u -> T.Text     -- ^ the verification key which is sent in an email.
    userResetPwdKey    :: u -> T.Text     -- ^ the reset password key which is sent in an email.

-- | Interface for the data type which stores the user info when using persistent.
--
--   You must make a data type that is either an instance of this class or of
--   'UserCredentials', depending on if you are using persistent or not.
class PersistUserCredentials u where
    userUsernameF       :: P.EntityField u Username
    userPasswordHashF   :: P.EntityField u B.ByteString
    userEmailF          :: P.EntityField u T.Text
    userEmailVerifiedF  :: P.EntityField u Bool
    userEmailVerifyKeyF :: P.EntityField u T.Text
    userResetPwdKeyF    :: P.EntityField u T.Text
    uniqueUsername      :: T.Text -> P.Unique u
    uniqueEmailaddress  :: T.Text -> P.Unique u

    -- | Creates a new user for use during 'addNewUser'.  The starting reset password
    -- key should be the empty string.
    userCreate :: Username
               -> T.Text       -- ^ unverified email
               -> T.Text       -- ^ email verification key
               -> B.ByteString -- ^ hashed and salted password
               -> u

-- | These are the database operations to load and update user data.
--
-- Persistent users can use 'AccountPersistDB' and don't need to create their own instance.
-- If you are not using persistent or are using persistent but want to customize the database
-- activity, you must manually make a monad an instance of this class.  You can use any monad
-- for which you can write 'runAccountDB', but typically the monad will be a newtype of HandlerT.
-- For example,
--
-- > newtype MyAccountDB a = MyAccountDB {runMyAccountDB :: HandlerT MyApp IO a}
-- >    deriving (Monad, MonadIO)
-- > instance AccountDB MyAccountDB where
-- >     ....
--
class AccountDB m where
    -- | The data type which stores the user.  Must be an instance of 'UserCredentials'.
    type UserAccount m

    -- | Load a user by username or email
    loadUser :: Username -> m (Maybe (UserAccount m))

    -- | Create new account.  The password reset key should be added as an empty string.
    -- The creation can fail with an error message, in which case the error is set in a
    -- message and the post handler redirects to 'newAccountR'.
    addNewUser :: Username     -- ^ username
               -> T.Text       -- ^ unverified email
               -> T.Text       -- ^ the email verification key
               -> B.ByteString -- ^ hashed and salted password
               -> m (Either T.Text (UserAccount m))

    -- | Mark the account as successfully verified.  This should reset the email validation key
    -- to the empty string.
    verifyAccount :: UserAccount m -> m ()

    -- | Change/set the users email verification key.
    setVerifyKey :: UserAccount m
                 -> T.Text -- ^ the verification key
                 -> m ()

    -- | Change/set the users password reset key.
    setNewPasswordKey :: UserAccount m
                      -> T.Text -- ^ the key
                      -> m ()

    -- | Set a new hashed password.  This should also set the password reset key to the empty
    -- string.
    setNewPassword :: UserAccount m
                   -> B.ByteString -- ^ hashed password
                   -> m ()

-- | A class to send email.
--
-- Both of the methods are implemented by default to just log a message,
-- so during development there are no required methods.  For production,
-- I recommend <http://hackage.haskell.org/package/mime-mail>.
class AccountSendEmail master where
    sendVerifyEmail :: Username
                    -> T.Text -- ^ email address
                    -> T.Text -- ^ verification URL
                    -> HandlerT master IO ()
    sendVerifyEmail uname email url =
        $(logInfo) $ T.concat [ "Verification email for "
                              , uname
                              , " (", email, "): "
                              , url
                              ]

    sendNewPasswordEmail :: Username
                         -> T.Text -- ^ email address
                         -> T.Text -- ^ new password URL
                         -> HandlerT master IO ()
    sendNewPasswordEmail uname email url =
        $(logInfo) $ T.concat [ "Reset password email for "
                              , uname
                              , " (", email, "): "
                              , url
                              ]

-- | The main class controlling the account plugin.
--
-- You must make your database instance of 'AccountDB' and your master site
-- an instance of this class.  The only required method is 'runAccountDB', although
-- this class contains many other methods to customize the behavior of the account plugin.
--
-- Continuing the example from the manual creation of 'AccountDB', a minimal instance is
--
-- > instance YesodAuthAccount MyAccountDB MyApp where
-- >     runAccountDB = runMyAccountDB
--
-- If instead you are using persistent and have made an instance of 'PersistUserCredentials',
-- a minimal instance is
--
-- > instance YesodAuthAccount (AccountPersistDB MyApp User) MyApp where
-- >    runAccountDB = runAccountPersistDB
--
class (YesodAuth master
      , AccountSendEmail master
      , AccountDB db
      , UserCredentials (UserAccount db)
      , RenderMessage master FormMessage
      ) => YesodAuthAccount db master | master -> db where

    -- | Run a database action.  This is the only required method.
    runAccountDB :: db a -> HandlerT master IO a

    -- | A form validator for valid usernames during new account creation.
    --
    -- By default this allows usernames made up of 'isAlphaNum'.  You can also ignore
    -- this validation and instead validate in 'addNewUser', but validating here
    -- allows the validation to occur before database activity (checking existing
    -- username) and before random salt creation (requires IO).
    checkValidUsername :: (MonadHandler m, HandlerSite m ~ master)
                       => Username -> m (Either T.Text Username)
    checkValidUsername u | T.all isAlphaNum u = return $ Right u
    checkValidUsername _ = do
        mr <- getMessageRender
        return $ Left $ mr MsgInvalidUsername

    checkValidEmail :: (MonadHandler m, HandlerSite m ~ master)
                    => Email -> m (Either T.Text Email)
    checkValidEmail u = do
        mr <- getMessageRender
        return . either (Left . (\e -> mr MsgInvalidEmail' <> ": " <> T.pack e))
                        (Right . TE.decodeUtf8 . toByteString)
                      . validate
                      $ TE.encodeUtf8 u

    -- | A form validator for valid usernames or emails during login.
    --
    -- By default this allows usernames made up of 'isAlphaNum', plus '@' and '.'.
    -- You can also ignore this validation and instead validate in 'addNewUser',
    -- but validating here allows the validation to occur before database activity
    -- (checking existing username) and before random salt creation (requires IO).
    checkValidLogin :: (MonadHandler m, HandlerSite m ~ master)
                    => Username -> m (Either T.Text Username)
    checkValidLogin u = do
      validUser <- checkValidUsername u
      validEmail<- checkValidEmail u
      return $ case validUser of
        Left _ -> validEmail
        Right _ -> validUser
    -- | What to do when the user logs in and the email has not yet been verified.
    --
    -- By default, supports both HTML and JSON responses.
    --
    --   * HTML: Displays a message and contains 'resendVerifyEmailForm', allowing
    --     the user to resend the verification email.  The handler is run inside the post
    --     handler for login, so you can call 'setCreds' to preform a successful login.
    --
    --   * JSON: Returns @{ unverified: true }@ and status code 401.
    unregisteredLogin :: UserAccount db -> HandlerT Auth (HandlerT master IO) TypedContent
    unregisteredLogin u =
        selectRep $ do
            provideRep $ do
                tm <- getRouteToParent
                lift $ defaultLayout $ do
                    setTitleI MsgEmailUnverified
                    [whamlet|
                      <p>_{MsgEmailUnverified}
                      ^{resendVerifyEmailWidget (username u) tm}
                    |]
            provideRep $ do
                let obj = A.object ["unverified" A..= True, "message" A..= msg]
                    msg = "User account has not been verified (check your e-mail)" :: T.Text
                void $ sendResponseStatus unauthorized401 obj
                return obj


    -- | The new account page.
    --
    -- This is the page which is displayed on a GET to 'newAccountR', and defaults to
    -- an embedding of 'newAccountWidget'.
    getNewAccountR :: HandlerT Auth (HandlerT master IO) Html
    getNewAccountR = do
        tm <- getRouteToParent
        lift $ defaultLayout $ do
            setTitleI Msg.RegisterLong
            newAccountWidget tm

    -- | Handles new account creation.
    --
    -- By default, this processes 'newAccountForm', calls 'createNewAccount', sets a message
    -- and redirects to LoginR.  If an error occurs, a message is set and the user is
    -- redirected to 'newAccountR'.
    postNewAccountR :: HandlerT Auth (HandlerT master IO) Html
    postNewAccountR = do
        tm <- getRouteToParent
        mr <- lift getMessageRender
        ((result, _), _) <- lift $ runFormPost $ renderDivs newAccountForm
        mdata <- case result of
                    FormMissing -> invalidArgs ["Form is missing"]
                    FormFailure msg -> return $ Left msg
                    FormSuccess d -> return $ if newAccountPassword1 d == newAccountPassword2 d
                                        then Right d
                                        else Left [mr Msg.PassMismatch]
        case mdata of
            Left errs -> do
                setMessage $ toHtml $ T.concat errs
                redirect newAccountR

            Right d -> do void $ lift $ createNewAccount d tm
                          redirect LoginR

    -- | Should the password reset inside this plugin be allowed?  Defaults to True
    allowPasswordReset :: master -> Bool
    allowPasswordReset _ = True

    -- | The page which prompts for a username and sends an email allowing password reset.
    --   By default, it embeds 'resetPasswordWidget'.
    getResetPasswordR :: HandlerT Auth (HandlerT master IO) Html
    getResetPasswordR = do
        tm <- getRouteToParent
        lift $ defaultLayout $ do
            setTitleI Msg.PasswordResetTitle
            resetPasswordWidget tm

    -- | The page which allows the user to set a new password.
    --
    -- This is called only when the email key has been verified as correct (True),
    -- or when the user is logged in (False). By default, it embeds 'newPasswordWidget'.
    setPasswordHandler :: Bool -> UserAccount db -> HandlerT Auth (HandlerT master IO) Html
    setPasswordHandler withKey u = do
        tm <- getRouteToParent
        lift $ defaultLayout $ do
            setTitleI Msg.SetPassTitle
            newPasswordWidget withKey u tm

    -- Get text username from an AuthId
    getTextId :: Proxy master -> AuthId master -> HandlerT Auth (HandlerT master IO) T.Text

    -- | Used for i18n of 'AccountMsg', defaults to 'defaultAccountMsg'.  To support
    -- multiple languages, you can implement this method using the various translations
    -- from "Yesod.Auth.Account.Message".
    renderAccountMessage :: master -> [T.Text] -> AccountMsg -> T.Text
    renderAccountMessage _ _ = defaultAccountMsg

instance YesodAuthAccount db master => RenderMessage master AccountMsg where
    renderMessage = renderAccountMessage

-- | True if user is currently logged in.
-- Only looks in session data, not if user is still present in database.
-- (See https://github.com/yesodweb/yesod/issues/486 )
-- Preferably, this should use requireAuthId instead, but my type foo is not enough for that...
-- Use runIfLogged instead
loggedInUser :: (YesodAuthAccount db master) => HandlerT Auth (HandlerT master IO) T.Text
loggedInUser = do
  y <- lift getYesod
  getTextId (return y) =<< lift requireAuthId

-- | Runs an action if the user is properly logged in
-- (cookie is set, user is on database and email is verified)
runIfLogged :: YesodAuthAccount db master => HandlerT Auth (HandlerT master IO) b -> HandlerT Auth (HandlerT master IO) b
runIfLogged action = do
    muser <- lift . runAccountDB . loadUser =<< loggedInUser
    case muser of
      Just u-> if userEmailVerified u
        then action
        else redirect LoginR
      Nothing -> redirect LoginR

-- | Salt and hash a password.
hashPassword :: MonadIO m => T.Text -> m B.ByteString
hashPassword pwd = liftIO $ PS.makePassword (TE.encodeUtf8 pwd) 12

-- | Verify a password
verifyPassword :: T.Text       -- ^ password
               -> B.ByteString -- ^ hashed password
               -> Bool
verifyPassword pwd = PS.verifyPassword (TE.encodeUtf8 pwd)

nonceGen :: Nonce.Generator
nonceGen = unsafePerformIO Nonce.new
{-# NOINLINE nonceGen #-}

-- | Randomly create a new verification key.
newVerifyKey :: MonadIO m => m T.Text
newVerifyKey = Nonce.nonce128urlT nonceGen

---------------------------------------------------------------------------------------------------



-- | Lens getter
infixl 8 ^.
(^.) :: a -> ((b -> Const b b') -> a -> Const b a') -> b
x ^. l = getConst $ l Const x

instance (P.PersistEntity u, PersistUserCredentials u) => UserCredentials (P.Entity u) where
    username u = u ^. fieldLens userUsernameF
    userPasswordHash u = u ^. fieldLens userPasswordHashF
    userEmail u = u ^. fieldLens userEmailF
    userEmailVerified u = u ^. fieldLens userEmailVerifiedF
    userEmailVerifyKey u = u ^. fieldLens userEmailVerifyKeyF
    userResetPwdKey u = u ^. fieldLens userResetPwdKeyF

-- | Internal state for the AccountPersistDB monad.
data PersistFuncs master user = PersistFuncs {
      pGet :: T.Text -> HandlerT master IO (Maybe (P.Entity user))
    , pInsert :: Username -> user -> HandlerT master IO (Either T.Text (P.Entity user))
    , pUpdate :: P.Entity user -> [P.Update user] -> HandlerT master IO ()
}

-- | A newtype which when using persistent is an instance of 'AccountDB'.
newtype AccountPersistDB master user a = AccountPersistDB (ReaderT (PersistFuncs master user) (HandlerT master IO) a)
    deriving (Monad, MonadIO, Functor, Applicative)

instance (Yesod master, PersistUserCredentials user) => AccountDB (AccountPersistDB master user) where
    type UserAccount (AccountPersistDB master user) = P.Entity user

    loadUser name = AccountPersistDB $ do
        f <- ask
        lift $ pGet f name

    addNewUser name email key pwd = AccountPersistDB $ do
        f <- ask
        lift $ pInsert f name $ userCreate name email key pwd

    verifyAccount u = AccountPersistDB $ do
        f <- ask
        lift $ pUpdate f u [ userEmailVerifiedF P.=. True
                           , userEmailVerifyKeyF P.=. ""]

    setVerifyKey u key = AccountPersistDB $ do
        f <- ask
        lift $ pUpdate f u [userEmailVerifyKeyF P.=. key]

    setNewPasswordKey u key = AccountPersistDB $ do
        f <- ask
        lift $ pUpdate f u [userResetPwdKeyF P.=. key]

    setNewPassword u pwd = AccountPersistDB $ do
        f <- ask
        lift $ pUpdate f u [ userPasswordHashF P.=. pwd
                           , userResetPwdKeyF P.=. ""]

-- | Use this for 'runAccountDB' if you are using 'AccountPersistDB' as your database type.
runAccountPersistDB :: ( Yesod master
                       , YesodPersist master
                       , P.PersistEntity user
                       , PersistUserCredentials user
                       , b ~ YesodPersistBackend master
#if MIN_VERSION_persistent(2,1,0)
                       , b ~ PersistEntityBackend user
                       , PersistUnique b
#else
                       , PersistMonadBackend (b (HandlerT master IO)) ~ P.PersistEntityBackend user
                       , P.PersistUnique (b (HandlerT master IO))
                       , P.PersistQuery (b (HandlerT master IO))
#endif
                       , YesodAuthAccount db master
                       , db ~ AccountPersistDB master user
                       )
                       => AccountPersistDB master user a -> HandlerT master IO a
runAccountPersistDB (AccountPersistDB m) = runReaderT m funcs
    where funcs = PersistFuncs {
                      pGet = \u -> runDB $ do
                          byUser <- P.getBy . uniqueUsername $ u
                          maybe    (P.getBy . uniqueEmailaddress $ u) (return . Just) byUser
                    , pInsert = \name u -> do mentity <- runDB $ P.insertBy u
                                              mr <- getMessageRender
                                              case mentity of
                                                 Left _ -> return $ Left $ mr $ MsgUsernameExists name
                                                 Right k -> return $ Right $ P.Entity k u
                    , pUpdate = \(P.Entity key _) u -> runDB $ P.update key u
                    }
