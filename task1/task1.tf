//First set the Region and Profile

provider "aws" {
  region  = "ap-south-1"
  profile = "Ris"
}

resource "tls_private_key" "privatekey" {
  algorithm   = "RSA"
  rsa_bits=2048
}

resource "aws_key_pair" "keypair" {
  key_name   = "terraformkey"
  public_key = "${tls_private_key.privatekey.public_key_openssh}"
  depends_on = [tls_private_key.privatekey]
}

resource "local_file" "key" {
    content    = "${tls_private_key.privatekey.private_key_pem}"
    filename   = "terraformkey.pem"
	file_permission= 0400
    depends_on = [aws_key_pair.keypair]
}


resource "aws_security_group" "firewall" {
  name        = "myfirewall"
  description = "Allow TCP"
  vpc_id      = "vpc-681c0300"

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
tags = {
    Name = "terraform_SG"
  }
}

//Creating EC2 Instance

resource "aws_instance" "webserver" {
  ami           = "ami-0447a12f28fddb066"
  instance_type = "t2.micro"
  key_name = "terraformkey"
  security_groups = ["myfirewall"]
  connection {
    type     = "ssh"
    user     = "ec2-user"
    private_key = "${tls_private_key.privatekey.private_key_pem}"
    host     = aws_instance.webserver.public_ip
  }

  provisioner "remote-exec" {
    inline = [
      "sudo yum install httpd  php git -y",
      "sudo systemctl restart httpd",
      "sudo systemctl enable httpd",
    ]
  }
  
  tags = {
    Name = "myserver"
  }
}

//Creating EBS Volume

resource "aws_ebs_volume" "tfvol" {
  availability_zone = aws_instance.webserver.availability_zone
  size              = 1

  tags = {
    Name = "EBS"
  }
}

//Attaching EBSto EC2 instance

resource "aws_volume_attachment" "EBS_ATTACH" {
  depends_on = [ 
         aws_ebs_volume.tfvol,
  ]
  device_name = "/dev/sdh"
  volume_id   = aws_ebs_volume.tfvol.id
  instance_id = aws_instance.webserver.id
  force_detach= true
}

//connect to instance and format,mount,download github code

resource "null_resource" "nullremote3"  {

depends_on = [
    aws_volume_attachment.EBS_ATTACH,
  ]


  connection {
    type     = "ssh"
    user     = "ec2-user"
    private_key = "${tls_private_key.privatekey.private_key_pem}"
    host     = aws_instance.webserver.public_ip
  }

provisioner "remote-exec" {
    inline = [
      "sudo mkfs.ext4  /dev/xvdh",
      "sudo mount  /dev/xvdh  /var/www/html",
      "sudo rm -rf /var/www/html/*",
      "sudo git clone https://github.com/shriris18/task1.git /var/www/html/",
    ]
  }
}

//creating S3 bucket

resource "aws_s3_bucket" "TERRAFORM_S3" {
  
  acl    = "public-read"
  versioning {
enabled=true
}
}

//creating S3 bucket_object

resource "aws_s3_bucket_object" "object" {
  bucket = aws_s3_bucket.TERRAFORM_S3.bucket
  key    = "WEB_IMAGE"
  acl = "public-read"
  source="test.jpg"
  etag = filemd5("test.jpg")
}

// creating cloudfront for s3 bucket

resource "aws_cloudfront_distribution" "s3_distribution" {
depends_on = [
   null_resource.nullremote3,
  ]
  origin {
    domain_name = aws_s3_bucket.TERRAFORM_S3.bucket_regional_domain_name
    origin_id   = "my_first_origin"
  }

  enabled             = true
  is_ipv6_enabled     = true
  comment             = "TERRAFORM_IMAGE_IN_CF"
  default_root_object = "WEB_IMAGE"
    default_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "my_first_origin"
    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "allow-all"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
  }

  # Cache behavior with precedence 0
  ordered_cache_behavior {
    path_pattern     = "/content/immutable/*"
    allowed_methods  = ["GET", "HEAD", "OPTIONS"]
    cached_methods   = ["GET", "HEAD", "OPTIONS"]
    target_origin_id = "my_first_origin"

    forwarded_values {
      query_string = false
      headers      = ["Origin"]

      cookies {
        forward = "none"
      }
    }

    min_ttl                = 0
    default_ttl            = 86400
    max_ttl                = 31536000
    compress               = true
    viewer_protocol_policy = "redirect-to-https"
  }

  # Cache behavior with precedence 1
  ordered_cache_behavior {
    path_pattern     = "/content/*"
    allowed_methods  = ["GET", "HEAD", "OPTIONS"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "my_first_origin"

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }

    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
    compress               = true
    viewer_protocol_policy = "redirect-to-https"
  }

  price_class = "PriceClass_200"

  restrictions {
    geo_restriction {
      restriction_type = "whitelist"
      locations        = ["US", "CA", "GB", "DE","IN"]
    }
  }

  tags = {
    Environment = "production"
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
connection {
        type    = "ssh"
        user    = "ec2-user"
        private_key = "${tls_private_key.privatekey.private_key_pem}"
	host     = aws_instance.webserver.public_ip
    }
provisioner "remote-exec" {
        inline  = [
            # "sudo su << \"EOF\" \n echo \"<img src='${self.domain_name}'>\" >> /var/www/html/index.html \n \"EOF\""
            "sudo su << EOF",
            "echo \"<center><img src='http://${self.domain_name}/${aws_s3_bucket_object.object.key}' height='500px' width='600px'></center>\" >> /var/www/html/index.html",
            "EOF"
        ]
    }

}



//launching chrome as soon as infrastructure is created

resource "null_resource" "nulllocal1"  {


depends_on = [
    null_resource.nullremote3,aws_cloudfront_distribution.s3_distribution
  ]

	provisioner "local-exec" {
	    command = "chrome  ${aws_instance.webserver.public_ip}"
  	}
}
