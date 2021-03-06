// @flow
import * as React from 'react';
import {
  Button,
  Input,
  Modal,
  Text
} from '@tarantool.io/ui-kit';

type InputModalState = {
  value: string
}

type InputModalProps = {
  className?: string,
  confirmText: string,
  initialValue?: string,
  placeholder?: string,
  visible?: boolean,
  title: string,
  text: React.Node,
  subText?: string,
  onConfirm: (name: string) => void,
  onClose: () => void
}

export class InputModal extends React.PureComponent<InputModalProps, InputModalState> {
  constructor(props: InputModalProps) {
    super(props);

    this.state = {
      value: props.initialValue || ''
    };
  }

  componentDidUpdate(prevProps: InputModalProps) {
    if (prevProps.initialValue !== this.props.initialValue) {
      this.setState({
        value: this.props.initialValue
      });
    }
  }

  updateValue = (e: InputEvent) => {
    if (e.target instanceof HTMLInputElement) {
      this.setState({ value: e.target.value });
    }
  }

  render() {
    const {
      className,
      confirmText,
      visible,
      title,
      text,
      placeholder,
      subText,
      onConfirm,
      onClose
    } = this.props;

    const { value } = this.state;

    return (
      <Modal
        className={className}
        title={title}
        visible={visible}
        onClose={onClose}
        footerControls={[
          <Button intent={'base'} onClick={onClose} text='Cancel' />,
          <Button intent={'primary'} onClick={() => onConfirm(value)} text={confirmText} />
        ]}
      >
        <Text>{text}</Text>
        <Input value={value} onChange={this.updateValue} placeholder={placeholder} />
        {subText && <Text>{subText}</Text>}
      </Modal>
    );
  }
}
