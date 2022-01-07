//
//  MessageCell.swift
//  ZegoLiveDemo
//
//  Created by zego on 2021/12/16.
//

import UIKit

class MessageCell: UITableViewCell {
    
    @IBOutlet weak var backView: UIView!
    @IBOutlet weak var contentLabel: UILabel!
    @IBOutlet weak var ownerLabel: UILabel!
    @IBOutlet weak var labelWidthConstraint: NSLayoutConstraint!
    
    
    var model:MessageModel?{
        didSet {
            contentLabel.attributedText = model?.attributedContent
            labelWidthConstraint.constant = model?.messageWidth ?? 0
            ownerLabel.isHidden = !model!.isOwner
        }
    }
    
    override func awakeFromNib() {
        super.awakeFromNib()
        // Initialization code
        backView.layer.cornerRadius = 13.0
        backView.clipsToBounds = true
        
        ownerLabel.layer.cornerRadius = 9.0
        ownerLabel.clipsToBounds = true
        ownerLabel.text = ZGLocalizedString("room_page_host")
    }

    
}
