//
//  ZegoUserService.swift
//  ZegoLiveAudioRoomDemo
//
//  Created by Kael Ding on 2021/12/13.
//

import Foundation
import ZIM
import ZegoExpressEngine

protocol UserServiceDelegate : AnyObject  {
    func connectionStateChanged(_ state: ZIMConnectionState, _ event: ZIMConnectionEvent)
    /// receive user join room
    func roomUserJoin(_ users: [UserInfo])
    /// reveive user leave room
    func roomUserLeave(_ users: [UserInfo])
    /// receive custom command: invitation
    func receiveTakeSeatInvitation()
}

extension UserServiceDelegate {
    func roomUserJoin(_ users: [UserInfo]) { }
    func roomUserLeave(_ users: [UserInfo]) { }
    func receiveTakeSeatInvitation() { }
}

class UserService: NSObject {
    // MARK: - Public
    private let delegates = NSHashTable<AnyObject>.weakObjects()
    var localInfo: UserInfo?
    var userList = DictionaryArrary<String, UserInfo>()
    var coHostList: [CoHostSeatModel] = []
    
    override init() {
        super.init()
        
        // RoomManager didn't finish init at this time.
        DispatchQueue.main.async {
            RoomManager.shared.addZIMEventHandler(self)
        }
    }
    
    func addUserServiceDelegate(_ delegate: UserServiceDelegate) {
        self.delegates.add(delegate)
    }
    
    /// user login with user info and `ZIM token`
    func login(_ user: UserInfo, _ token: String, callback: RoomCallback?) {
        
        guard let userID = user.userID else {
            guard let callback = callback else { return }
            callback(.failure(.paramInvalid))
            return
        }
        
        guard let userName = user.userName else {
            guard let callback = callback else { return }
            callback(.failure(.paramInvalid))
            return
        }
        
        let zimUser = ZIMUserInfo()
        zimUser.userID = userID
        zimUser.userName = userName
        
        ZIMManager.shared.zim?.login(zimUser, token: token, callback: { error in
            var result: ZegoResult
            if error.code == .ZIMErrorCodeSuccess {
                self.localInfo = user
                result = .success(())
            } else {
                result = .failure(.other(Int32(error.code.rawValue)))
            }
            guard let callback = callback else { return }
            callback(result)
        })
    }
    
    /// user logout
    func logout() {
        ZIMManager.shared.zim?.logout()
        RoomManager.shared.logoutRtcRoom(true)
    }
        
    /// get the number of chat rooms available online
    func getOnlineRoomUsersNum(callback: OnlineRoomUsersCountCallback?) {
        guard let roomID = RoomManager.shared.roomService.info.roomID else {
            assert(false, "room ID can't be nil")
            guard let callback = callback else { return }
            callback(.failure(.failed))
            return
        }
        
        ZIMManager.shared.zim?.queryRoomOnlineMemberCount(roomID, callback: { count, error in
            var result: Result<UInt32, ZegoError>
            if error.code == .ZIMErrorCodeSuccess {
                result = .success(count)
            } else {
                result = .failure(.other(Int32(error.code.rawValue)))
            }
            guard let callback = callback else { return }
            callback(result)
        })
    }
    
    /// get users of target page.
    func getOnlineRoomUsers(_ page: UInt, callback: OnlineRoomUsersCallback?) {
        guard let roomID = RoomManager.shared.roomService.info.roomID else {
            assert(false, "room ID can't be nil")
            guard let callback = callback else { return }
            callback(.failure(.failed))
            return
        }
        let config = ZIMQueryMemberConfig()
        config.count = 100
        config.nextFlag = String(page)
        ZIMManager.shared.zim?.queryRoomMember(roomID, config: config, callback: { zimUsers, nextFlag, error in
            
            if error.code != .ZIMErrorCodeSuccess {
                guard let callback = callback else { return }
                callback(.failure(.other(Int32(error.code.rawValue))))
                return
            }
            var users: [UserInfo] = []
            
            for zimUser in zimUsers {
                let role: UserRole = zimUser.userID == RoomManager.shared.roomService.info.hostID ? .host : .participant
                let user = UserInfo(zimUser.userID, zimUser.userName, role)
                users.append(user)
            }
            guard let callback = callback else { return }
            callback(.success(users))
        })
    }
    
    /// send an invitation message to add co-host
    func addCoHost(_ userID: String, callback: RoomCallback?) {
        let invitation = CustomCommand(.invitation)
        invitation.targetUserID = userID
        guard let json = invitation.json(),
              let data = json.data(using: .utf8) else {
            guard let callback = callback else { return }
            callback(.failure(.failed))
            return
        }
        
        let customMessage: ZIMCustomMessage = ZIMCustomMessage(message: data)
        ZIMManager.shared.zim?.sendPeerMessage(customMessage, toUserID: userID, callback: { _, error in
            var result: ZegoResult
            if error.code == .ZIMErrorCodeSuccess {
                result = .success(())
            } else {
                result = .failure(.other(Int32(error.code.rawValue)))
            }
            guard let callback = callback else { return }
            callback(result)
        })
    }
    
    /// respond to the co-host invitation
    func respondCoHostInvitation(_ accept: Bool, callback: RoomCallback?) {
    
        guard let hostID = RoomManager.shared.roomService.info.hostID else {
            assert(false, "the room ID can't be nil")
            guard let callback = callback else { return }
            callback(.failure(.failed))
            return
        }
        
        let respond = CustomCommand(.respondInvitation)
        respond.targetUserID = hostID
        respond.content = CustomCommandContent(accept: accept)
        
        guard let json = respond.json(),
              let data = json.data(using: .utf8) else {
            guard let callback = callback else { return }
            callback(.failure(.failed))
            return
        }
        
        let customMessage: ZIMCustomMessage = ZIMCustomMessage(message: data)
        ZIMManager.shared.zim?.sendPeerMessage(customMessage, toUserID: hostID, callback: { _, error in
            var result: ZegoResult
            if error.code == .ZIMErrorCodeSuccess {
                result = .success(())
            } else {
                result = .failure(.other(Int32(error.code.rawValue)))
            }
            guard let callback = callback else { return }
            callback(result)
        })
    }
    
    /// the participant request to host to be a co-host
    func requestToCoHost(callback: RoomCallback?) {
        guard let parameters = getRequestOrCancelToHostParameters(true) else {
            guard let callback = callback else { return }
            callback(.failure(.failed))
            return
        }
        setRoomAttributes(parameters.0, parameters.1, parameters.2, callback)
    }
    
    func cancelRequestToCoHost(callback: RoomCallback?) {
        guard let parameters = getRequestOrCancelToHostParameters(false) else {
            guard let callback = callback else { return }
            callback(.failure(.failed))
            return
        }
        setRoomAttributes(parameters.0, parameters.1, parameters.2, callback)
    }
    
    /// take to co-host seat
    func takeCoHostSeat(callback: RoomCallback?) {
        guard let parameters = getTakeOrLeaveSeatParameters(true) else {
            guard let callback = callback else { return }
            callback(.failure(.failed))
            return
        }
        setRoomAttributes(parameters.0, parameters.1, parameters.2, callback)
    }
    
    
    /// leave co-host seat
    func leaveCoHostSeat(callback: RoomCallback?) {
        guard let parameters = getTakeOrLeaveSeatParameters(false) else {
            guard let callback = callback else { return }
            callback(.failure(.failed))
            return
        }
        setRoomAttributes(parameters.0, parameters.1, parameters.2, callback)
    }
    
    /// the host respond to the participant
    func respondCoHostRequest(_ agree: Bool, callback: RoomCallback?) {
        
    }
    
    /// prohibit turning on the mic
    func muteUser(_ isMuted: Bool, userID: String, callback: RoomCallback?) {
        guard let hostID = RoomManager.shared.roomService.info.hostID,
              let myUserID = localInfo?.userID
        else {
            assert(false, "the hostID or roomID cannot be nil")
            guard let callback = callback else { return }
            callback(.failure(.failed))
            return
        }
        
        // only the host have access to call this method
        if hostID != myUserID {
            guard let callback = callback else { return }
            callback(.failure(.noPermission))
            return
        }
        
        guard let parameters = getSeatChangeParameters(userID ,enable: isMuted, flag: 0) else {
            guard let callback = callback else { return }
            callback(.failure(.failed))
            return
        }
        
        setRoomAttributes(parameters.0, parameters.1, parameters.2, callback)
    }
    
    /// mic operation
    func micOperation(_ open: Bool) {
        
        guard let parameters = getSeatChangeParameters(enable: open, flag: 0) else {
            return
        }
        
        setRoomAttributes(parameters.0, parameters.1, parameters.2, nil)
        
        // open mic
        ZegoExpressEngine.shared().muteMicrophone(!open)
    }
    
    /// camera operation
    func cameraOpen(_ open: Bool) {
        
        guard let parameters = getSeatChangeParameters(enable: open, flag: 1) else {
            return
        }
        
        setRoomAttributes(parameters.0, parameters.1, parameters.2, nil)
        
        // open camera
        ZegoExpressEngine.shared().enableCamera(open)
    }
}

// MARK: - Private
extension UserService {
    private func setRoomAttributes(_ attributes: [String : String],
                                   _ roomID: String,
                                   _ config: ZIMRoomAttributesSetConfig, _ callback: RoomCallback?) {
        ZIMManager.shared.zim?.setRoomAttributes(attributes, roomID: roomID, config: config, callback: { error in
            guard let callback = callback else { return }
            if error.code == .ZIMErrorCodeSuccess {
                callback(.success(()))
            } else {
                callback(.failure(.other(Int32(error.code.rawValue))))
            }
        })
    }
    
    // get request or cancel request to host parameters
    private func getRequestOrCancelToHostParameters(_ isRequest: Bool) ->
    ([String: String], String, ZIMRoomAttributesSetConfig)? {
        guard let hostID = RoomManager.shared.roomService.info.hostID,
              let roomID = RoomManager.shared.roomService.info.roomID,
              let myUserID = localInfo?.userID
        else {
            assert(false, "the hostID or roomID cannot be nil")
            return nil
        }
        
        let operation = RoomManager.shared.roomService.operation.copy() as! OperationCommand
        operation.action.seq += 1
        operation.action.operatorID = myUserID
        operation.action.targetID = hostID
        
        if isRequest {
            operation.action.type = .requestToCoHost
            operation.coHostList.append(myUserID)
        } else {
            operation.action.type = .cancelRequestCoHost
            operation.coHostList = operation.coHostList.filter { $0 != myUserID }
        }
        
        let config = ZIMRoomAttributesSetConfig()
        config.isDeleteAfterOwnerLeft = true
        config.isForce = true
        config.isUpdateOwner = true
        
        let attributes = operation.attributes(.coHost)
        
        return (attributes, roomID, config)
    }
    
    // get take or leave seat parameters
    private func getTakeOrLeaveSeatParameters(_ isTake: Bool) ->
    ([String: String], String, ZIMRoomAttributesSetConfig)? {
        
        guard let roomID = RoomManager.shared.roomService.info.roomID,
              let myUserID = localInfo?.userID
        else {
            assert(false, "the userID or roomID cannot be nil")
            return nil
        }
        
        let operation = RoomManager.shared.roomService.operation.copy() as! OperationCommand
        operation.action.seq += 1
        operation.action.operatorID = myUserID
        operation.action.targetID = myUserID
        
        if isTake {
            operation.action.type = .takeCoHostSeat
            let seat: CoHostSeatModel = CoHostSeatModel()
            seat.userID = myUserID
            operation.seatList.append(seat)
        } else {
            operation.action.type = .leaveCoHostSeat
            operation.seatList = operation.seatList.filter { $0.userID != myUserID }
        }
        
        let config = ZIMRoomAttributesSetConfig()
        config.isDeleteAfterOwnerLeft = true
        config.isForce = true
        config.isUpdateOwner = true
        
        let attributes = operation.attributes(.seat)
        
        return (attributes, roomID, config)
    }
    
    // get the seat releated parameters
    // flag: 0 - mic, 1 - camera, 2 - mute
    private func getSeatChangeParameters(_ targetUserID: String = "", enable: Bool, flag: Int) ->
    ([String: String], String, ZIMRoomAttributesSetConfig)? {
        
        guard let roomID = RoomManager.shared.roomService.info.roomID,
              let myUserID = localInfo?.userID
        else {
            assert(false, "the hostID or roomID cannot be nil")
            return nil
        }
        
        let operation = RoomManager.shared.roomService.operation.copy() as! OperationCommand
        operation.action.seq += 1
        operation.action.operatorID = myUserID
        operation.action.targetID = myUserID
        
        guard let seatModel = operation.seatList.filter({ $0.userID == myUserID }).first else {
            assert(false, "myself did not on the seat")
            return nil
        }
        if flag == 0 {
            seatModel.mic = enable
            operation.action.type = .mic
        } else if flag == 1 {
            seatModel.camera = enable
            operation.action.type = .camera
        } else if flag == 2 {
            seatModel.isMuted = enable
            operation.action.type = .mute
        }
        
        let attributes = operation.attributes(.seat)
        
        let config = ZIMRoomAttributesSetConfig()
        config.isDeleteAfterOwnerLeft = true
        config.isForce = true
        config.isUpdateOwner = true
        
        return (attributes, roomID, config)
    }
}

extension UserService : ZIMEventHandler {
    func zim(_ zim: ZIM, connectionStateChanged state: ZIMConnectionState, event: ZIMConnectionEvent, extendedData: [AnyHashable : Any]) {
        for obj  in delegates.allObjects {
            let delegate = obj as? UserServiceDelegate
            guard let delegate = delegate else { continue }
            delegate.connectionStateChanged(state, event)
        }
    }
    
    func zim(_ zim: ZIM, roomMemberJoined memberList: [ZIMUserInfo], roomID: String) {
        var addUsers: [UserInfo] = []
        for zimUser in memberList {
            let role: UserRole = zimUser.userID == RoomManager.shared.roomService.info.hostID ? .host : .participant
            let user = UserInfo(zimUser.userID, zimUser.userName, role)
            addUsers.append(user)
            guard let userID = user.userID else { continue }
            userList.addObj(userID, user)
            if localInfo?.userID == userID {
                localInfo = user
            }
        }
        
        for obj in delegates.allObjects {
            if let delegate = obj as? UserServiceDelegate {
                delegate.roomUserJoin(addUsers)
            }
        }
    }
    
    func zim(_ zim: ZIM, roomMemberLeft memberList: [ZIMUserInfo], roomID: String) {
        var leftUsers: [UserInfo] = []
        for zimUser in memberList {
            let role: UserRole = zimUser.userID == RoomManager.shared.roomService.info.hostID ? .host : .participant
            let user = UserInfo(zimUser.userID, zimUser.userName, role)
            leftUsers.append(user)
            guard let userID = user.userID else { continue }
            userList.removeObj(userID)
        }
        
        for obj in delegates.allObjects {
            if let delegate = obj as? UserServiceDelegate {
                delegate.roomUserLeave(leftUsers)
            }
        }
    }
    
    // recevie a invitation via this method
    func zim(_ zim: ZIM, receivePeerMessage messageList: [ZIMMessage], fromUserID: String) {
        for message in messageList {
            guard let message = message as? ZIMCustomMessage else { continue }
            guard let jsonStr = String(data: message.message, encoding: .utf8) else { continue }
            let command: CustomCommand? = ZegoJsonTool.jsonToModel(type: CustomCommand.self, json: jsonStr)
            guard let command = command else { continue }
            if command.targetUserID?.count == 0 { continue }
            //TODO: to add delegate
            for delegate in delegates.allObjects {
                guard let delegate = delegate as? UserServiceDelegate else { continue }
                delegate.receiveTakeSeatInvitation()
            }
        }
    }
}
